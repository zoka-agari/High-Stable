-- Single-Sided Staking Contract - Utility Module
-- Contains helper functions that don't modify state

local bint = require('.bint')(256)
local json = require('json')
local config = require('mintprotocol.config')

local utils = {}

-- Math operations using bint
utils.math = {
  add = function(a, b)
    return tostring(bint(a) + bint(b))
  end,

  subtract = function(a, b)
    return tostring(bint(a) - bint(b))
  end,

  multiply = function(a, b)
    return tostring(bint(a) * bint(b))
  end,

  divide = function(a, b)
    return tostring(bint.__idiv(bint(a), bint(b)))
  end,

  toBalanceValue = function(a)
    return tostring(bint(a))
  end,

  isGreaterThan = function(a, b)
    return bint(a) > bint(b)
  end,

  isGreaterThanOrEqual = function(a, b)
    return bint(a) >= bint(b)
  end,

  isLessThan = function(a, b)
    return bint(a) < bint(b)
  end,

  isZero = function(a)
    return bint(a) == bint.zero()
  end,

  isPositive = function(a)
    return bint(a) > bint.zero()
  end,

  isEqual = function(a, b)
    return bint(a) == bint(b)
  end
}

-- Determine which MINT token to use based on the staked token
-- Returns config.MINT_TESTNET_TOKEN for test tokens and config.MINT_TOKEN for real tokens
utils.getMintTokenForStakedToken = function(stakedToken)
  return config.getMintTokenForStakedToken(stakedToken)
end

-- Check if a token is a MINT token (either mainnet or testnet)
utils.isMintToken = function(token)
  return token == config.MINT_TOKEN or token == config.MINT_TESTNET_TOKEN
end

-- Generate operation ID
utils.operationId = function(sender, token, type)
  return token .. '-' .. type .. '-' .. sender .. '-' .. os.time()
end

-- Get user's token from a pair (identifies which token in a pair is not the MINT token)
utils.getUsersToken = function(tokenA, tokenB)
  if utils.isMintToken(tokenA) then
    return tokenB
  else
    return tokenA
  end
end

-- Get the MINT token in a pair
utils.getMintToken = function(tokenA, tokenB)
  if utils.isMintToken(tokenA) then
    return tokenA
  elseif utils.isMintToken(tokenB) then
    return tokenB
  else
    return nil -- Neither token is a MINT token
  end
end

-- Event logging function with color formatting
utils.logEvent = function(eventType, details)
  print(config.Colors.GRAY .. '[Event] ' .. eventType .. ': ' .. json.encode(details) .. config.Colors.RESET)
end

-- Helper function to format token quantities for display
utils.formatTokenQuantity = function(quantity, token, isLPToken)
  -- Get the correct number of decimals for this token
  local decimals

  if isLPToken then
    decimals = config.getDecimalsForLP(token)
  else
    decimals = config.getDecimalsForToken(token)
  end

  -- Convert to string to ensure consistent handling
  local quantityStr = tostring(quantity)

  -- Simple whole number formatting if no decimal places needed
  if decimals == 0 then
    return quantityStr
  end

  -- Add decimal point if needed
  if #quantityStr <= decimals then
    -- Pad with zeros if needed
    quantityStr = string.rep('0', decimals - #quantityStr + 1) .. quantityStr
    quantityStr = '0.' .. quantityStr:sub(2)
  else
    -- Insert decimal point
    local decimalPos = #quantityStr - decimals
    quantityStr = quantityStr:sub(1, decimalPos) .. '.' .. quantityStr:sub(decimalPos + 1)
  end

  -- Trim trailing zeros
  return quantityStr:gsub('%.?0*$', '')
end

-- Format timestamp to readable date string
utils.formatTimestamp = function(timestamp)
  return os.date('%Y-%m-%d %H:%M:%S', timestamp)
end

-- Calculate time elapsed since a given timestamp (in seconds)
utils.timeElapsedSince = function(timestamp)
  return os.time() - timestamp
end

-- Format duration in seconds to human-readable format
utils.formatDuration = function(milliseconds)
  local totalSeconds = math.floor(milliseconds / 1000)
  local ms = milliseconds % 1000

  local days = math.floor(totalSeconds / 86400)
  totalSeconds = totalSeconds % 86400

  local hours = math.floor(totalSeconds / 3600)
  totalSeconds = totalSeconds % 3600

  local minutes = math.floor(totalSeconds / 60)
  totalSeconds = totalSeconds % 60

  local seconds = totalSeconds

  local result = ''
  if days > 0 then
    result = days .. 'd '
  end
  if hours > 0 or days > 0 then
    result = result .. hours .. 'h '
  end
  if minutes > 0 or hours > 0 or days > 0 then
    result = result .. minutes .. 'm '
  end

  result = result .. seconds

  -- Add milliseconds part with decimal point
  if ms > 0 then
    result = result .. '.' .. string.format('%03d', ms)
  end

  result = result .. 's'

  return result
end

-- Check if an operation has timed out
utils.isOperationTimedOut = function(operation)
  if not operation or not operation.timestamp then
    return false
  end

  return utils.timeElapsedSince(operation.timestamp) > config.OPERATION_TIMEOUT
end

-- Apply excess multiplier to ensure enough MINT tokens for swapping
utils.calculateAdjustedMintAmount = function(mintAmount)
  local adjustedAmount = utils.math.divide(
    utils.math.multiply(mintAmount, config.EXCESS_MULTIPLIER),
    config.EXCESS_DIVISOR
  )

  -- Ensure the result is at least 1
  if utils.math.isLessThan(adjustedAmount, '1') then
    return '1'
  else
    return adjustedAmount
  end
end

-- Format message for Send function to improve readability
utils.formatMessage = function(target, action, payload)
  local message = {
    Target = target,
    Action = action
  }

  -- Add all payload fields to the message
  for key, value in pairs(payload) do
    message[key] = value
  end

  return message
end

-- Create a message reply with standard format
utils.createReply = function(action, payload)
  local reply = {
    Action = action
  }

  -- Add all payload fields to the reply
  if payload then
    for key, value in pairs(payload) do
      reply[key] = value
    end
  end

  return reply
end

-- Convert a table to JSON string, handle nested tables
utils.tableToJson = function(tbl)
  return json.encode(tbl)
end

-- Parse JSON string to table, handle errors gracefully
utils.parseJson = function(jsonStr)
  local success, result = pcall(json.decode, jsonStr)
  if success then
    return result
  else
    utils.logEvent('JsonParseError', { error = result, input = jsonStr })
    return nil
  end
end

utils.math.isLessThanOrEqual = function(a, b)
  return bint(a) <= bint(b)
end

return utils
