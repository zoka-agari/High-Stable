-- Single-Sided Staking Contract - Operations Module
-- Handles tracking, cleanup, and management of pending operations

local config = require('config')
local state = require('state')
local utils = require('utils')
local security = require('security')

local operations = {}

-- Handler patterns
operations.patterns = {
  -- Pattern for cleanup operation
  cleanup = function(msg)
    return msg.Tags.Action == 'Cleanup'
  end
}

-- Clean up stale pending operations (older than the configured timeout)
operations.cleanStaleOperations = function()
  local now = os.time()
  local pendingOperations = state.getPendingOperations()
  local staleIds = {}

  -- Identify stale operations
  for id, op in pairs(pendingOperations) do
    if op.timestamp and (now - op.timestamp) > config.OPERATION_TIMEOUT then
      table.insert(staleIds, id)
    end
  end

  -- Remove stale operations
  for _, id in ipairs(staleIds) do
    state.removePendingOperation(id)
  end

  return #staleIds
end

-- Create a new operation
operations.createOperation = function(type, token, sender, amount, amm)
  local opId = utils.operationId(sender, token, type)

  local operation = {
    id = opId,
    type = type,
    token = token,
    sender = sender,
    amount = amount,
    amm = amm,
    status = 'pending',
    timestamp = os.time()
  }

  -- Add mintAmount field for stake operations
  if type == 'stake' then
    operation.mintAmount = '0'
  end

  -- Add lpTokens field for unstake operations
  if type == 'unstake' then
    local position = state.getStakingPosition(token, sender)
    operation.lpTokens = position and position.lpTokens or '0'
    operation.mintAmount = position and position.mintAmount or '0'
  end

  state.setPendingOperation(opId, operation)
  return opId, operation
end

-- Update operation status
operations.updateStatus = function(id, status)
  return state.updatePendingOperation(id, { status = status })
end

-- Complete an operation
operations.complete = function(id)
  return state.completePendingOperation(id)
end

-- Fail an operation
operations.fail = function(id)
  return state.failPendingOperation(id)
end

-- Get operation details
operations.get = function(id)
  return state.getPendingOperation(id)
end

-- Check if operation exists
operations.exists = function(id)
  return state.getPendingOperation(id) ~= nil
end

-- Check if operation is in specific state
operations.isInState = function(id, expectedState)
  local operation = state.getPendingOperation(id)
  return operation and operation.status == expectedState
end

-- Check if operation has timed out
operations.hasTimedOut = function(id)
  local operation = state.getPendingOperation(id)
  if not operation or not operation.timestamp then
    return false
  end

  return (os.time() - operation.timestamp) > config.OPERATION_TIMEOUT
end

-- Count operations by status
operations.countByStatus = function(status)
  local count = 0
  local pendingOperations = state.getPendingOperations()

  for _, op in pairs(pendingOperations) do
    if op.status == status then
      count = count + 1
    end
  end

  return count
end

-- Handler implementations
operations.handlers = {
  -- Handler for cleanup operation
  cleanup = function(msg)
    security.assertIsAuthorized(msg.From)

    local startCount = state.countPendingOperations()

    local removedCount = operations.cleanStaleOperations()

    local endCount = state.countPendingOperations()

    utils.logEvent('CleanupCompleted', {
      caller = msg.From,
      operationsBeforeCleanup = startCount,
      operationsAfterCleanup = endCount,
      operationsRemoved = removedCount
    })

    msg.reply({
      Action = 'Cleanup-Complete',
      ['Operations-Removed'] = tostring(removedCount),
      ['Timestamp'] = tostring(os.time())
    })
  end
}

return operations
