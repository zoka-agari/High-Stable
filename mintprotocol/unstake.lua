-- Single-Sided Staking Contract - Unstake Module
-- Handles all unstaking-related operations

local config = require('mintprotocol.config')
local state = require('mintprotocol.state')
local utils = require('mintprotocol.utils')
local security = require('mintprotocol.security')
local impermanent_loss = require('mintprotocol.impermanent_loss')
local operations = require('mintprotocol.operations')

local unstake = {}

unstake.patterns = {
  -- Pattern for initial unstake request
  unstake = function(msg)
    return msg.Tags.Action == 'Unstake' and msg.Tags['Token'] ~= nil
  end,

  -- Pattern for AMM burn confirmation
  burnConfirmation = function(msg)
    return msg.Tags.Action == 'Burn-Confirmation'
  end
}

-- Helper function to validate burn operation
local function validateBurnOperation(msg)
  security.assertNotPaused()

  local operationId = msg.Tags['X-Operation-Id']
  local operation = security.verifyOperation(operationId, 'unstake', 'pending')
  security.assertIsValidAmm(msg.From, operation.amm)

  return operation
end

-- Helper function to extract token amounts from burn confirmation
local function extractTokenAmounts(msg, operation)
  local usersToken = utils.getUsersToken(msg.Tags['Token-A'], msg.Tags['Token-B'])

  return {
    withdrawnUserToken = msg.Tags['Withdrawn-' .. usersToken],
    withdrawnMintToken = msg.Tags['Withdrawn-' .. config.MINT_TOKEN],
    initialUserTokenAmount = operation.amount,
    initialMintTokenAmount = operation.mintAmount,
    burnedLpTokens = msg.Tags['Burned-Pool-Tokens'],
    usersToken = usersToken
  }
end

-- REMOVED: handleImpermanentLoss function is now replaced with the call to impermanent_loss.processCompensation

-- Helper function to handle user token profit sharing
local function handleUserTokenProfitSharing(tokenData, operation)
  if utils.math.isLessThan(tokenData.withdrawnUserToken, tokenData.initialUserTokenAmount) or
    utils.math.isEqual(tokenData.withdrawnUserToken, tokenData.initialUserTokenAmount) then
    return {
      userTokenProfit = '0',
      feeShareAmount = '0',
      amountToSendUser = tokenData.withdrawnUserToken
    }
  end

  -- User has made profit
  local userTokenProfit = utils.math.subtract(tokenData.withdrawnUserToken, tokenData.initialUserTokenAmount)

  -- Calculate fee split: 99% to user, 1% to protocol (adjustable ratio)
  local protocolFees = utils.math.divide(
    utils.math.multiply(userTokenProfit, config.PROTOCOL_FEE_PERCENTAGE),
    config.FEE_DIVISOR
  )
  local userShare = utils.math.subtract(userTokenProfit, protocolFees)

  -- Adjust amount to send user
  local amountToSendUser = utils.math.subtract(tokenData.withdrawnUserToken, protocolFees)

  -- Log fee sharing for user token
  utils.logEvent('UserTokenFeeSharing', {
    sender = operation.sender,
    token = operation.token,
    tokenName = config.AllowedTokensNames[operation.token],
    initialAmount = tokenData.initialUserTokenAmount,
    withdrawnAmount = tokenData.withdrawnUserToken,
    profit = userTokenProfit,
    userShare = userShare,
    protocolShare = protocolFees,
    operationId = operation.id
  })

  return {
    userTokenProfit = userTokenProfit,
    feeShareAmount = userShare,
    amountToSendUser = amountToSendUser
  }
end

-- Calculate the rebased value of MINT tokens after accounting for weekly rebasing
local function calculateRebasedMintAmount(initialAmount, stakedDate, currentDate)
  -- Calculate number of weeks between staking and unstaking
  local secondsPerWeek = 7 * 24 * 60 * 60
  local stakingDurationSeconds = currentDate - stakedDate
  local weeks = math.floor(stakingDurationSeconds / secondsPerWeek)

  -- If staked for less than a week, no rebasing occurred
  if weeks == 0 then
    return initialAmount
  end

  -- Calculate rebased amount
  -- For each week, apply (1 - 0.0025) reduction
  local rebaseRatePerWeek = 0.9975 -- 1 - 0.0025 (weekly burn rate)

  -- Convert the rebase rate to a fixed-point representation with 8 decimal places
  local denomination = 8
  local rebaseFactor = math.floor(rebaseRatePerWeek ^ weeks * 10 ^ denomination)
  local rebaseFactorBint = utils.math.toBalanceValue(tostring(rebaseFactor))
  local divisor = utils.math.toBalanceValue(tostring(10 ^ denomination))

  -- Apply rebasing to initial amount
  local rebasedAmount = utils.math.multiply(initialAmount, rebaseFactorBint)
  rebasedAmount = utils.math.divide(rebasedAmount, divisor)

  return rebasedAmount
end

-- Helper function to handle MINT token profit sharing with rebasing adjustments
local function handleMintTokenProfitSharing(tokenData, operation)
  -- If initial amount is zero or withdrawnMintToken is less than or equal to zero, there's no profit
  if utils.math.isZero(tokenData.initialMintTokenAmount) or
    not utils.math.isPositive(tokenData.withdrawnMintToken) then
    return '0' -- No profit to share
  end

  -- Calculate what the initial amount would be worth now, after rebasing
  local rebasedInitialAmount = calculateRebasedMintAmount(
    tokenData.initialMintTokenAmount,
    operation.timestamp,
    os.time()
  )

  -- If withdrawn amount is less than the rebased initial amount, there's no profit
  if utils.math.isLessThan(tokenData.withdrawnMintToken, rebasedInitialAmount) then
    return '0'
  end

  -- Calculate actual profit by comparing withdrawn amount to rebased initial amount
  local mintTokenProfit = utils.math.subtract(tokenData.withdrawnMintToken, rebasedInitialAmount)

  -- Calculate fee split: protocol fee percentage to treasury, rest to user
  local protocolFee = utils.math.divide(
    utils.math.multiply(mintTokenProfit, config.PROTOCOL_FEE_PERCENTAGE),
    config.FEE_DIVISOR
  )
  local userShare = utils.math.subtract(mintTokenProfit, protocolFee)

  -- Send user's share of MINT profits
  Send({
    Target = config.MINT_TOKEN,
    Action = 'Transfer',
    Recipient = operation.sender,
    Quantity = userShare,
    ['X-MINT-Profit-Share'] = 'true',
    ['X-Operation-Id'] = operation.id,
    ['X-Rebased-Initial-Amount'] = rebasedInitialAmount -- Add this for transparency
  })

  -- Log MINT profit sharing with rebasing info
  utils.logEvent('MintTokenProfitSharing', {
    sender = operation.sender,
    initialMintAmount = tokenData.initialMintTokenAmount,
    rebasedInitialAmount = rebasedInitialAmount,
    withdrawnMintAmount = tokenData.withdrawnMintToken,
    profit = mintTokenProfit,
    userShare = userShare,
    protocolShare = protocolFee,
    weeks = math.floor((os.time() - operation.timestamp) / (7 * 24 * 60 * 60)),
    operationId = operation.id
  })

  return userShare
end


-- Helper function to send tokens and notify user
local function sendTokensAndNotify(operation, tokenData, results)
  -- Return user's tokens
  Send({
    Target = operation.token,
    Action = 'Transfer',
    Recipient = operation.sender,
    Quantity = results.amountToSendUser,
    ['X-Message'] = 'Unstake-Complete',
    ['X-Token'] = operation.token,
    ['X-TokenName'] = config.AllowedTokensNames[operation.token],
    ['X-Amount'] = results.amountToSendUser,
    ['X-Initial-User-Token-Amount'] = tokenData.initialUserTokenAmount,
    ['X-Withdrawn-User-Token'] = tokenData.withdrawnUserToken,
    ['X-Initial-MINT-Amount'] = tokenData.initialMintTokenAmount,
    ['X-Withdrawn-MINT'] = tokenData.withdrawnMintToken,
    ['X-IL-Compensation'] = results.ilCompensation,
    ['X-User-Token-Profit-Share'] = results.feeShareAmount,
    ['X-MINT-Profit-Share'] = results.mintProfitShare,
    ['X-LP-Tokens-Burned'] = tokenData.burnedLpTokens
  })

  -- Notify user with a separate message
  Send({
    Target = operation.sender,
    Action = 'Unstake-Complete',
    Token = operation.token,
    TokenName = config.AllowedTokensNames[operation.token],
    ['Initial-Amount'] = tokenData.initialUserTokenAmount,
    ['Withdrawn-Amount'] = results.amountToSendUser,
    ['IL-Compensation'] = results.ilCompensation,
    ['Profit-Share'] = results.feeShareAmount,
    ['MINT-Profit-Share'] = results.mintProfitShare,
    ['LP-Tokens-Burned'] = tokenData.burnedLpTokens,
    ['Operation-Id'] = operation.id
  })
end

-- Handler implementations for unstaking operations
unstake.handlers = {
  -- Handler for initial unstake request
  unstake = function(msg)
    security.assertNotPaused()

    local token = msg.Tags['Token']
    local sender = msg.From

    -- Validate token and staking position
    security.assertTokenAllowed(token)
    security.assertStakingPositionExists(token, sender)
    security.assertStakingPositionHasTokens(token, sender)

    -- Get the corresponding AMM for this token
    local amm = security.getAmmForToken(token)

    local position = state.getStakingPosition(token, sender)
    local opId = utils.operationId(sender, token, 'unstake')

    -- Log unstake initiated
    utils.logEvent('UnstakeInitiated', {
      sender = sender,
      token = token,
      tokenName = config.AllowedTokensNames[token],
      amount = position and position.amount or '0',
      lpTokens = position and position.lpTokens or '0',
      operationId = opId
    })

    -- Store the position values before clearing
    local positionAmount = position and position.amount or '0'
    local positionLpTokens = position and position.lpTokens or '0'
    local positionMintAmount = position and position.mintAmount or '0'

    -- Clear staking position (checks-effects-interactions pattern)
    state.clearStakingPosition(token, sender)

    -- Create pending operation
    state.setPendingOperation(opId, {
      id = opId,
      type = 'unstake',
      token = token,
      sender = sender,
      amount = positionAmount,
      lpTokens = positionLpTokens,
      mintAmount = positionMintAmount,
      amm = amm,
      status = 'pending',
      timestamp = os.time()
    })

    -- Remove liquidity from AMM by burning LP tokens
    Send({
      Target = amm,
      Action = 'Burn',
      Quantity = positionLpTokens,
      ['X-Operation-Id'] = opId,
    })

    -- Send confirmation to user
    Send({
      Target = sender,
      Action = 'Unstake-Started',
      Token = token,
      TokenName = config.AllowedTokensNames[token],
      Amount = positionAmount,
      ['Operation-Id'] = opId
    })
  end,

  -- Handler for AMM burn confirmation
  -- Handler for AMM burn confirmation
  burnConfirmation = function(msg)
    -- Step 1: Validate the operation
    local operation = validateBurnOperation(msg)

    -- Step 2: Extract token amounts
    local tokenData = extractTokenAmounts(msg, operation)

    -- Step 3: Mark operation as completed (checks-effects-interactions)
    operations.complete(msg.Tags['X-Operation-Id'])

    -- Step 4: Process impermanent loss and profit sharing
    -- Use the impermanent_loss module to handle IL compensation
    local ilCompensation = impermanent_loss.processCompensation(tokenData, operation)

    local userTokenResults = handleUserTokenProfitSharing(tokenData, operation)

    local mintProfitShare = handleMintTokenProfitSharing(tokenData, operation)

    -- Step 5: Send tokens and notify user
    local results = {
      amountToSendUser = userTokenResults.amountToSendUser,
      ilCompensation = ilCompensation,
      feeShareAmount = userTokenResults.feeShareAmount,
      mintProfitShare = mintProfitShare
    }

    sendTokensAndNotify(operation, tokenData, results)

    -- Log unstake completed
    utils.logEvent('UnstakeComplete', {
      sender = operation.sender,
      token = operation.token,
      tokenName = config.AllowedTokensNames[operation.token],
      initialAmount = tokenData.initialUserTokenAmount,
      withdrawnAmount = tokenData.withdrawnUserToken,
      lpTokensBurned = tokenData.burnedLpTokens,
      ilCompensation = ilCompensation,
      userTokenProfit = userTokenResults.userTokenProfit,
      mintProfitShare = mintProfitShare,
      operationId = operation.id
    })
  end
}

return unstake
