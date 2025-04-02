local AnalyticsService = game:GetService("AnalyticsService")
local MarketplaceService = game:GetService("MarketplaceService")
local ProfileService = require(script.Parent.ProfileService)
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Economy = {}

-- Debug flag for centralized debug output
local DebugMode = RunService:IsStudio()

-- Constants for configuration 
local profileStoreName = RunService:IsStudio() and "DEV" or "TestingPhase"

local profileTemplate = {
	currencies = {},
	processedReceipts = {},
	lastReceiptCleanup = 0
}

local receiptRetentionDays = 30 -- days to keep receipts
local autoSaveInterval = 300 -- 5 minutes
local maxTransactionRetry = 3
local transactionRetryDelay = 0.5

-- Currency type definitions
export type CurrencyData = {
	displayName: string,
	abbreviation: string,
	saveKey: string,
	canBePurchased: boolean,
	canBeEarned: boolean,
	exchangeRateToRobux: number,
	defaultValue: number,
	minValue: number,
	maxValue: number,
	purchaseIDs: { [number]: {SKU: string, ID: number} }
}

export type Currency = CurrencyData & {
	SetValue: (Currency, playerID: number, value: number, reason: string?, transactionType: any?) -> (boolean, string?),
	GetValue: (Currency, playerID: number) -> (number, boolean),
	IncrementValue: (Currency, playerID: number, amount: number, reason: string?, transactionType: any?) -> (boolean, string?),
	DecrementValue: (Currency, playerID: number, amount: number, reason: string?, transactionType: any?) -> (boolean, string?),
	TransferValue: (Currency, fromPlayerID: number, toPlayerID: number, amount: number, reason: string?, transactionType: any?) -> (boolean, string?)
}

export type TransactionInfo = {
	transactionId: string,
	timestamp: number,
	playerID: number,
	currencyKey: string,
	previousValue: number,
	newValue: number,
	changeAmount: number,
	reason: string?,
	transactionType: any?
}

-- Format amount with appropriate suffix
local function formatAmount(num)
	if num >= 1e15 then -- quadrillion
		return string.format("%.1fQ", num/1e15):gsub("%.0+Q$", "Q")
	elseif num >= 1e12 then -- trillion
		return string.format("%.1fT", num/1e12):gsub("%.0+T$", "T")
	elseif num >= 1e9 then -- billion
		return string.format("%.1fB", num/1e9):gsub("%.0+B$", "B")
	elseif num >= 1e6 then -- million
		return string.format("%.1fM", num/1e6):gsub("%.0+M$", "M")
	elseif num >= 1e3 then -- thousand
		return string.format("%.1fK", num/1e3):gsub("%.0+K$", "K")
	else
		return tostring(num)
	end
end

local Currencies = {}

-- Setup ProfileService with a complete template
local ProfileStore = ProfileService.GetProfileStore(profileStoreName, profileTemplate)

local profiles = {}
local transactionLocks = {}
local receiptProcessingMap = {}
local transactionQueues = {} -- Mapping from playerID to queue of transactions
local developerProductMapping = {}

-- Process the next transaction in a player's queue without busy waiting.
local function processNextTransaction(playerID)
	local queue = transactionQueues[playerID]
	if not queue or #queue == 0 then return end

	local transaction = table.remove(queue, 1)

	-- Execute the transaction function safely
	local success, result = pcall(transaction.callback, table.unpack(transaction.params))
	-- Call the completion callback synchronously
	if transaction.onComplete then
		transaction.onComplete(success, result)
	end

	-- Continue processing if any remain
	if #queue > 0 then
		processNextTransaction(playerID)
	else
		transactionQueues[playerID] = nil
	end
end

-- Enqueue a transaction to be processed.
local function enqueueTransaction(playerID, callback, onComplete, ...)
	if type(playerID) ~= "number" then
		error("Invalid playerID for transaction enqueue")
	end
	transactionQueues[playerID] = transactionQueues[playerID] or {}
	local params = {...}
	table.insert(transactionQueues[playerID], {
		callback = callback,
		params = params,
		onComplete = onComplete
	})
	-- If this is the only transaction in the queue, process it immediately.
	if #transactionQueues[playerID] == 1 then
		task.spawn(function() processNextTransaction(playerID) end)
	end
	return true
end

-- Utility functions 
local function isValidNumber(value)
	return type(value) == "number" and value == value -- not NaN
end

local function generateTransactionID()
	return HttpService:GenerateGUID(false)
end

local function logTransaction(transactionInfo)
	local flowType = transactionInfo.changeAmount >= 0 and Enum.AnalyticsEconomyFlowType.Source or Enum.AnalyticsEconomyFlowType.Sink
	local transactionType = transactionInfo.transactionType or Enum.AnalyticsEconomyTransactionType.Gameplay

	local player = Players:GetPlayerByUserId(transactionInfo.playerID)
	if DebugMode then
		local playerName = player and player.Name or "Unknown Player"
		local logMessage = string.format(
			"[TRANSACTION] Player: %s | Type: %s | Flow: %s | Currency: %s | Change: %+d | New Balance: %d | Description: %s",
			playerName,
			transactionType.Name,
			flowType.Name,
			transactionInfo.currencyKey,
			transactionInfo.changeAmount,
			transactionInfo.newValue,
			transactionInfo.reason and transactionInfo.reason:sub(1,50) or "N/A"
		)
		print(logMessage)
	end

	AnalyticsService:LogEconomyEvent(
		player,
		flowType,
		transactionInfo.currencyKey,
		math.abs(transactionInfo.changeAmount),
		transactionInfo.newValue,
		transactionType.Name,
		transactionInfo.reason and transactionInfo.reason:sub(1,50)
	)
end

-- Profile Management
local function cleanupOldReceipts(profile)
	if not profile or not profile.Data then return end
	local now = DateTime.now().UnixTimestampMillis * 1000
	if now - (profile.Data.lastReceiptCleanup or 0) < 86400 then return end -- run at most once per day
	local cutoffTime = now - (receiptRetentionDays * 86400)
	local receiptsRemoved = 0
	for receiptId, timestamp in pairs(profile.Data.processedReceipts) do
		if timestamp < cutoffTime then
			profile.Data.processedReceipts[receiptId] = nil
			receiptsRemoved = receiptsRemoved + 1
		end
	end
	profile.Data.lastReceiptCleanup = now
	if receiptsRemoved > 0 and DebugMode then
		print("[Economy] Cleaned up " .. receiptsRemoved .. " old receipts for player profile")
	end
end

local function safeGetProfile(playerID)
	local profile = profiles[playerID]
	if not profile then return nil, "Profile not loaded" end
	if not profile.Data then return nil, "Profile data corrupted" end
	profile.Data.currencies = profile.Data.currencies or {}
	return profile, nil
end

local function safeProfileOperation(playerID, callback)
	local profile, errorMsg = safeGetProfile(playerID)
	if not profile then
		return false, errorMsg
	end
	local success, result = pcall(callback, profile)
	if not success then
		warn("[Economy] Profile operation failed for player " .. playerID .. ": " .. tostring(result))
		return false, "Internal error: " .. tostring(result)
	end
	return true, result
end

local function scheduleAutoSave()
	while true do
		task.wait(autoSaveInterval)
		for playerID, profile in pairs(profiles) do
			if profile and profile.Data then
				task.spawn(function()
					local success, err = pcall(function()
						profile:Save()
					end)
					if not success and DebugMode then
						warn("[Economy] Auto-save failed for player " .. playerID .. ": " .. tostring(err))
					end
				end)
			end
		end
	end
end

-- Asynchronous wait for a transaction to complete using a BindableEvent
local function waitForTransaction(playerID, transactionFunc)
	local event = Instance.new("BindableEvent")
	enqueueTransaction(playerID, transactionFunc, function(success, result)
		event:Fire(success, result)
	end)
	local success, result = event.Event:Wait()
	event:Destroy()
	return success, result
end

-- Player Profile Initialization and Cleanup
local function playerAdded(player)
	local playerID = player.UserId
	if profiles[playerID] then
		warn("[Economy] Profile already loaded for player " .. playerID)
		return
	end
	if transactionLocks[playerID] then
		warn("[Economy] Profile is already being loaded for player " .. playerID)
		return
	end
	transactionLocks[playerID] = true

	local profile
	local success, errorMsg = pcall(function()
		profile = ProfileStore:LoadProfileAsync("Player_" .. playerID)
	end)
	transactionLocks[playerID] = nil

	if not success then
		warn("[Economy] Failed to load profile for player " .. playerID .. ": " .. tostring(errorMsg))
		if player:IsDescendantOf(Players) then
			player:Kick("Failed to load your data. Please rejoin.")
		end
		return
	end

	if profile then
		profile:AddUserId(playerID)
		profile:Reconcile()
		if player:IsDescendantOf(Players) then
			profiles[playerID] = profile
			profile:ListenToRelease(function()
				profiles[playerID] = nil
				if player:IsDescendantOf(Players) then
					player:Kick("Your data was loaded on another server. Please rejoin.")
				end
			end)
			cleanupOldReceipts(profile)
		else
			profile:Release()
		end
	else
		if player:IsDescendantOf(Players) then
			player:Kick("Your data is currently in use on another server. Please try again later.")
		end
	end
end

local function playerRemoving(player)
	local playerID = player.UserId
	local profile = profiles[playerID]
	if profile then
		-- Clear pending transactions by clearing the transaction queue
		transactionQueues[playerID] = nil
		pcall(function()
			profile:Save()
		end)
		profile:Release()
		profiles[playerID] = nil
	end
	transactionLocks[playerID] = nil
end

-- Currency Functions
local function initializeCurrency(currencyName, currencyData)
	-- Get value with validation and clamping.
	function currencyData:GetValue(playerID)
		local success, value = safeProfileOperation(playerID, function(profile)
			local curVal = profile.Data.currencies[self.saveKey]
			if curVal == nil then
				curVal = self.defaultValue
				profile.Data.currencies[self.saveKey] = curVal
			end
			if not isValidNumber(curVal) then
				warn("[Economy] Invalid currency value for player " .. playerID .. " (" .. self.saveKey .. "): " .. tostring(curVal))
				curVal = self.defaultValue
				profile.Data.currencies[self.saveKey] = curVal
			end
			-- Warn if value was out-of-range before clamping
			if curVal < self.minValue or curVal > self.maxValue then
				warn("[Economy] Currency value for player " .. playerID .. " (" .. self.saveKey .. ") was out-of-range: " .. curVal)
			end
			curVal = math.clamp(curVal, self.minValue, self.maxValue)
			profile.Data.currencies[self.saveKey] = curVal
			return curVal
		end)
		return success and value or self.defaultValue, success
	end

	-- Use IncrementValue for both increment and decrement
	function currencyData:IncrementValue(playerID, amount, reason, transactionType)
		if not isValidNumber(amount) or amount == 0 then
			return false, "Invalid amount"
		end

		-- Use a BindableEvent for synchronization
		local function performIncrement()
			return safeProfileOperation(playerID, function(profile)
				local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
				if not isValidNumber(currentValue) then
					currentValue = self.defaultValue
				end
				local newValue = currentValue + amount
				newValue = math.clamp(newValue, self.minValue, self.maxValue)
				local transactionInfo = {
					transactionId = generateTransactionID(),
					timestamp = DateTime.now().UnixTimestampMillis * 1000,
					playerID = playerID,
					currencyKey = self.saveKey,
					previousValue = currentValue,
					newValue = newValue,
					changeAmount = amount,
					reason = reason or "IncrementValue",
					transactionType = transactionType
				}
				profile.Data.currencies[self.saveKey] = newValue
				logTransaction(transactionInfo)
				return true
			end)
		end

		return waitForTransaction(playerID, performIncrement)
	end

	function currencyData:DecrementValue(playerID, amount, reason, transactionType)
		if not isValidNumber(amount) or amount < 0 then
			return false, "Invalid amount"
		end
		-- Decrement by using negative increment
		return self:IncrementValue(playerID, -amount, reason or "DecrementValue", transactionType or Enum.AnalyticsEconomyTransactionType.Sink)
	end

	function currencyData:SetValue(playerID, value, reason, transactionType)
		if not isValidNumber(value) then
			return false, "Invalid value"
		end
		local function performSetValue()
			return safeProfileOperation(playerID, function(profile)
				local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
				local clampedValue = math.clamp(value, self.minValue, self.maxValue)
				if clampedValue ~= value then
					warn("[Economy] Value clamped for player " .. playerID .. " (" .. self.saveKey .. "): attempted " .. value .. ", clamped to " .. clampedValue)
				end
				local transactionInfo = {
					transactionId = generateTransactionID(),
					timestamp = DateTime.now().UnixTimestampMillis * 1000,
					playerID = playerID,
					currencyKey = self.saveKey,
					previousValue = currentValue,
					newValue = clampedValue,
					changeAmount = clampedValue - currentValue,
					reason = reason or "SetValue",
					transactionType = transactionType
				}
				profile.Data.currencies[self.saveKey] = clampedValue
				logTransaction(transactionInfo)
				return true
			end)
		end

		return waitForTransaction(playerID, performSetValue)
	end

	function currencyData:TransferValue(fromPlayerID, toPlayerID, amount, reason, transactionType)
		if not isValidNumber(amount) or amount <= 0 then
			return false, "Invalid amount"
		end
		if fromPlayerID == toPlayerID then
			return false, "Cannot transfer to same player"
		end

		-- Check sender balance first.
		local currentValue, success = self:GetValue(fromPlayerID)
		if not success then
			return false, "Failed to get sender's balance"
		end
		if currentValue < amount then
			return false, "Insufficient funds"
		end

		local transferType = transactionType or Enum.AnalyticsEconomyTransactionType.Trade
		local senderSuccess, senderError, receiverSuccess, receiverError
		local completedSender, completedReceiver = false, false

		local function performSenderDecrement()
			return safeProfileOperation(fromPlayerID, function(profile)
				local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
				local newValue = math.clamp(currentValue - amount, self.minValue, self.maxValue)
				local transactionInfo = {
					transactionId = generateTransactionID(),
					timestamp = DateTime.now().UnixTimestampMillis * 1000,
					playerID = fromPlayerID,
					currencyKey = self.saveKey,
					previousValue = currentValue,
					newValue = newValue,
					changeAmount = -amount,
					reason = reason or "TransferSent",
					transactionType = transferType
				}
				profile.Data.currencies[self.saveKey] = newValue
				logTransaction(transactionInfo)
				return true
			end)
		end

		local function performReceiverIncrement()
			return safeProfileOperation(toPlayerID, function(profile)
				local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
				local newValue = math.clamp(currentValue + amount, self.minValue, self.maxValue)
				local transactionInfo = {
					transactionId = generateTransactionID(),
					timestamp = DateTime.now().UnixTimestampMillis * 1000,
					playerID = toPlayerID,
					currencyKey = self.saveKey,
					previousValue = currentValue,
					newValue = newValue,
					changeAmount = amount,
					reason = reason or "TransferReceived",
					transactionType = transferType
				}
				profile.Data.currencies[self.saveKey] = newValue
				logTransaction(transactionInfo)
				return true
			end)
		end

		local function performRollback()
			return safeProfileOperation(fromPlayerID, function(profile)
				local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
				local rollbackValue = math.clamp(currentValue + amount, self.minValue, self.maxValue)
				profile.Data.currencies[self.saveKey] = rollbackValue
				logTransaction({
					transactionId = generateTransactionID(),
					timestamp = DateTime.now().UnixTimestampMillis * 1000,
					playerID = fromPlayerID,
					currencyKey = self.saveKey,
					previousValue = currentValue,
					newValue = rollbackValue,
					changeAmount = amount,
					reason = "TransferRollback",
					transactionType = Enum.AnalyticsEconomyTransactionType.Source
				})
				return true
			end)
		end

		-- Process sender decrement
		senderSuccess, senderError = waitForTransaction(fromPlayerID, performSenderDecrement)
		completedSender = true

		-- If sender succeeded, process receiver increment.
		if senderSuccess then
			receiverSuccess, receiverError = waitForTransaction(toPlayerID, performReceiverIncrement)
			completedReceiver = true
			if not receiverSuccess then
				-- Attempt rollback; log if rollback fails.
				local rollbackSuccess, rollbackError = waitForTransaction(fromPlayerID, performRollback)
				if not rollbackSuccess then
					warn("[Economy] Rollback failed for transfer from player " .. fromPlayerID .. ": " .. (rollbackError or "Unknown error"))
				end
				return false, "Failed to credit receiver: " .. (receiverError or "Unknown error")
			end
		else
			return false, "Failed to debit sender: " .. (senderError or "Unknown error")
		end

		return true
	end

	-- Validation metatable for currencyData
	local expectedTypes = {
		displayName = "string",
		abbreviation = "string",
		saveKey = "string",
		canBePurchased = "boolean",
		canBeEarned = "boolean",
		exchangeRateToRobux = "number",
		defaultValue = "number",
		minValue = "number",
		maxValue = "number",
		purchaseIDs = "table",

		-- Currency methods
		SetValue = "function",
		GetValue = "function",
		IncrementValue = "function",
		DecrementValue = "function",
		TransferValue = "function",
	}

	local function isValidPurchaseIDs(tbl)
		if type(tbl) ~= "table" then
			return false, "purchaseIDs must be a table."
		end

		for k, v in pairs(tbl) do
			if type(k) ~= "number" then
				return false, "purchaseIDs key " .. tostring(k) .. " is not a number."
			end
			if type(v) ~= "table" then
				return false, "purchaseIDs value for key " .. tostring(k) .. " is not a table."
			end
			if type(v.SKU) ~= "string" then
				return false, "purchaseIDs[" .. tostring(k) .. "].SKU is not a string."
			end
			if type(v.ID) ~= "number" then
				return false, "purchaseIDs[" .. tostring(k) .. "].ID is not a number."
			end
		end

		return true
	end

	setmetatable(currencyData, {
		__newindex = function(self, key, value)
			local expectedType = expectedTypes[key]
			if not expectedType then
				error("Attempt to assign an undefined property: " .. tostring(key))
			end

			if type(value) ~= expectedType then
				error("Type mismatch for property " .. tostring(key) .. ": expected " .. expectedType .. ", got " .. type(value))
			end

			if key == "purchaseIDs" then
				local valid, errMsg = isValidPurchaseIDs(value)
				if not valid then
					error("Invalid purchaseIDs table: " .. errMsg)
				end
			end

			rawset(self, key, value)
		end,
	})

end

-- Initialize each currency.
for currencyName, currencyData in pairs(Currencies) do
	initializeCurrency(currencyName, currencyData)
end

-- Purchase and Receipt Processing (Public API)

function Economy.PurchaseCurrencyAsync(player, currencyName, currencyAmount)
	if not (player and player:IsA("Player")) then
		return false, "Invalid player"
	end
	if type(currencyName) ~= "string" then
		return false, "Invalid currency name"
	end

	local currency = Currencies[currencyName]
	if not currency then 
		return false, "Invalid currency: " .. tostring(currencyName)
	end

	if not currency.canBePurchased then
		return false, "Currency cannot be purchased: " .. tostring(currencyName)
	end

	if not isValidNumber(currencyAmount) or currencyAmount <= 0 then
		return false, "Invalid amount"
	end

	if not currency.purchaseIDs or not currency.purchaseIDs[currencyAmount] then
		return false, "No valid Purchase ID found for currency: " .. currencyName .. ", amount: " .. currencyAmount
	end

	local purchaseID = currency.purchaseIDs[currencyAmount].ID
	local success, errorMessage = pcall(function()
		MarketplaceService:PromptProductPurchase(player, purchaseID)
	end)
	if not success then
		warn("[Economy] Error prompting product purchase: " .. errorMessage)
		return false, "Failed to prompt purchase"
	end
	return true
end

function Economy.GetPurchaseOptions(currencyName): { amount: number, info: {SKU: string, ID: number} }?
	local currency = Currencies[currencyName]
	if not currency or not currency.canBePurchased then 
		return
	end
	local options = {} :: { amount: number, info: {SKU: string, ID: number} }
	for amount, productInfo in pairs(currency.purchaseIDs) do
		table.insert(options, { amount = amount, info = productInfo })
	end
	table.sort(options, function(a, b) return a.amount < b.amount end)
	return options
end

-- Public API functions for currency access
function Economy.GetCurrency(currencyName): Currency?
	if type(currencyName) ~= "string" then return end
	return Currencies[currencyName]
end

function Economy.GetAllCurrencies(): {Currency}
	local result = {}
	for name, currency in pairs(Currencies) do
		result[name] = currency
	end
	return result
end

function Economy.GetPlayerCurrencies(playerID): {Currency}
	local result = {}
	for name, currency in pairs(Currencies) do
		result[name] = currency:GetValue(playerID)
	end
	return result
end

function Economy.ProcessReceipt(receiptInfo)
	-- Validate required fields
	if not receiptInfo or not receiptInfo.PlayerId or not receiptInfo.ProductId then
		warn("[Economy] Invalid receiptInfo provided")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Studio mode: auto-grant with extra validation.
	if RunService:IsStudio() then
		if DebugMode then
			print("[Economy] Auto-granting purchase in Studio for Product ID:", receiptInfo.ProductId)
		end
		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if player then
			local mapping = developerProductMapping[receiptInfo.ProductId]
			if mapping then
				local currency = mapping.currencyData
				local success, errorMsg = currency:IncrementValue(
					receiptInfo.PlayerId,
					mapping.amount,
					mapping.currencyData.purchaseIDs[mapping.amount].SKU,
					Enum.AnalyticsEconomyTransactionType.IAP
				)
				if not success then
					warn("[Economy] Failed to grant currency in Studio: " .. (errorMsg or "Unknown error"))
				end
			else
				warn("[Economy] Unknown developer product ID in Studio: " .. tostring(receiptInfo.ProductId))
			end
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Production mode: Ensure PurchaseId exists.
	if not receiptInfo.PurchaseId then
		warn("[Economy] ReceiptId is nil. Generating fallback ReceiptId")
		receiptInfo.PurchaseId = HttpService:GenerateGUID(false)
	end

	-- Use a simple locking mechanism for receipt processing.
	if receiptProcessingMap[receiptInfo.PurchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	receiptProcessingMap[receiptInfo.PurchaseId] = true

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		receiptProcessingMap[receiptInfo.PurchaseId] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile, errorMsg = safeGetProfile(receiptInfo.PlayerId)
	if not profile then
		receiptProcessingMap[receiptInfo.PurchaseId] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if profile.Data.processedReceipts[receiptInfo.PurchaseId] then
		receiptProcessingMap[receiptInfo.PurchaseId] = nil
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local mapping = developerProductMapping[receiptInfo.ProductId]
	print(mapping)
	if not mapping then
		warn("[Economy] Unknown developer product ID: " .. tostring(receiptInfo.ProductId))
		receiptProcessingMap[receiptInfo.PurchaseId] = nil
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local currency = mapping.currencyData
	local success, errorMsg = currency:IncrementValue(
		receiptInfo.PlayerId, 
		mapping.amount, 
		mapping.currencyData.purchaseIDs[mapping.amount].SKU,
		Enum.AnalyticsEconomyTransactionType.IAP
	)
	if not success then
		warn("[Economy] Failed to grant currency for receipt " .. receiptInfo.PurchaseId .. ": " .. (errorMsg or "Unknown error"))
		receiptProcessingMap[receiptInfo.PurchaseId] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if DebugMode then
		print("[Economy] Purchase processed for product:", mapping.currencyData.purchaseIDs[mapping.amount].SKU)
	end

	profile.Data.processedReceipts[receiptInfo.PurchaseId] = DateTime.now().UnixTimestampMillis * 1000
	local saveSuccess, saveError = pcall(function() profile:Save() end)
	if not saveSuccess then
		warn("[Economy] Failed to save profile after purchase: " .. (saveError or "Unknown error"))
	end
	receiptProcessingMap[receiptInfo.PurchaseId] = nil
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function Economy.CreateCurrency(currencyName: string, currencyConfig: CurrencyData): Currency
	if Currencies[currencyName] then
		warn("[Economy] Currency " .. currencyName .. " already exists. Overwriting...")
	end

	Currencies[currencyName] = currencyConfig
	initializeCurrency(currencyName, Currencies[currencyName])

	if Currencies[currencyName].purchaseIDs then
		for amount, productInfo in pairs(currencyConfig.purchaseIDs) do
			developerProductMapping[productInfo.ID] = { 
				currencyName = currencyName,
				currencyData = currencyConfig, 
				amount = amount 
			}
		end
	end

	return Currencies[currencyName]
end

-- Connect player events
Players.PlayerAdded:Connect(playerAdded)
Players.PlayerRemoving:Connect(playerRemoving)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(playerAdded, player)
end

task.spawn(scheduleAutoSave)

-- let users decide so they can integrate with their other recpeipts to allow purchases that arent just economical
-- MarketplaceService.ProcessReceipt = Economy.ProcessReceipt

-- Lock the Economy module with a metatable to prevent external modifications.
setmetatable(Economy, {
	__newindex = function(table, key, value)
		error("Attempt to modify read-only Economy module property: " .. tostring(key))
	end,
	__metatable = "Locked"
})

return Economy
