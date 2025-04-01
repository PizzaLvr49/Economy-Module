local MarketplaceService = game:GetService("MarketplaceService")
local ProfileService = require(script.Parent.ProfileService)
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Economy = {}

-- Constants for configuration (camelCase)
local profileStoreName = "PlayerEconomy2" -- Incremented version for schema update
local profileTemplate = {
	currencies = {},
	processedReceipts = {},
	lastReceiptCleanup = 0
}
local receiptRetentionDays = 30 -- How long to keep processed receipts
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
	minValue: number, -- Added min value
	maxValue: number, -- Added max value
	purchaseIDs: { [number]: number } -- Amount of currency: Purchase ID
}

export type Currency = CurrencyData & {
	SetValue: (Currency, playerID: number, value: number) -> (boolean, string?),
	GetValue: (Currency, playerID: number) -> (number, boolean),
	IncrementValue: (Currency, playerID: number, amount: number) -> (boolean, string?),
	DecrementValue: (Currency, playerID: number, amount: number) -> (boolean, string?),
	TransferValue: (Currency, fromPlayerID: number, toPlayerID: number, amount: number) -> (boolean, string?)
}

export type TransactionInfo = {
	transactionId: string,
	timestamp: number,
	playerID: number,
	currencyKey: string,
	previousValue: number,
	newValue: number,
	changeAmount: number,
	reason: string?
}

-- Define currencies with complete configurations (PascalCase for objects)
local Currencies = {
	Cash = {
		displayName = "Cash",
		abbreviation = "$",
		saveKey = "Cash",
		canBePurchased = true,
		canBeEarned = true,
		exchangeRateToRobux = 10_000,
		defaultValue = 1000,
		minValue = 0,
		maxValue = 1_000_000_000, -- 1 billion max
		purchaseIDs = {
			[100] = 3253924294,
			[500] = 3253924295, -- Added more purchase options
			[1000] = 3253924296
		}
	},
	Gems = {
		displayName = "Gems",
		abbreviation = "💎",
		saveKey = "Gems",
		canBePurchased = true,
		canBeEarned = false,
		exchangeRateToRobux = 100,
		defaultValue = 100,
		minValue = 0,
		maxValue = 1_000_000, -- 1 million max
		purchaseIDs = {
			[50] = 3253924297, -- Added purchase IDs
			[100] = 3253924298,
			[500] = 3253924299
		}
	}
}

-- Setup ProfileService with a complete template
local ProfileStore = ProfileService.GetProfileStore(
	profileStoreName,
	profileTemplate
)

local profiles = {}
local transactionLocks = {} -- Track active transactions per player
local pendingTransactions = {} -- (Not used here; instead we simply wait)
local receiptProcessingMap = {} -- Track receipts being processed to prevent duplicates

-- Reverse mapping table for developer product IDs
-- Maps productID -> { currencyData, amount }
local developerProductMapping = {}
do
	for currencyName, currencyData in pairs(Currencies) do
		if currencyData.purchaseIDs then
			for amount, productId in pairs(currencyData.purchaseIDs) do
				developerProductMapping[productId] = { 
					currencyName = currencyName,
					currencyData = currencyData, 
					amount = amount 
				}
			end
		end
	end
end

-- Utility functions (camelCase)
local function isValidNumber(value)
	return type(value) == "number" and not (value ~= value) -- Check for NaN
end

local function generateTransactionID()
	return HttpService:GenerateGUID(false)
end

local function logTransaction(transactionInfo)
	-- In a production system, you would probably want to log this to a database
	-- For this example, we'll just print to output
	if RunService:IsStudio() then
		print(string.format("[Economy] Transaction %s: Player %d %s %+d %s (now %d)",
			transactionInfo.transactionId,
			transactionInfo.playerID,
			transactionInfo.currencyKey,
			transactionInfo.changeAmount,
			transactionInfo.reason or "",
			transactionInfo.newValue
			))
	end
	-- You could implement Analytics or DataStore logging here
	-- You could also send significant transactions to a webhook/API
end

-- Profile Management (camelCase functions)
local function cleanupOldReceipts(profile)
	if not profile or not profile.Data then return end

	local now = os.time()
	if now - (profile.Data.lastReceiptCleanup or 0) < 86400 then return end -- Only run once per day

	local cutoffTime = now - (receiptRetentionDays * 86400)
	local receiptsRemoved = 0

	for receiptId, timestamp in pairs(profile.Data.processedReceipts) do
		if timestamp < cutoffTime then
			profile.Data.processedReceipts[receiptId] = nil
			receiptsRemoved = receiptsRemoved + 1
		end
	end

	profile.Data.lastReceiptCleanup = now

	if receiptsRemoved > 0 and RunService:IsStudio() then
		print("[Economy] Cleaned up " .. receiptsRemoved .. " old receipts for player profile")
	end
end

local function safeGetProfile(playerID)
	local profile = profiles[playerID]
	if not profile then return nil, "Profile not loaded" end
	if not profile.Data then return nil, "Profile data corrupted" end

	-- Ensure currency table exists
	if not profile.Data.currencies then
		profile.Data.currencies = {}
	end

	return profile, nil
end

local function safeProfileOperation(playerID, callback)
	-- This function encapsulates safe profile operations with proper error handling
	local profile, errorMsg = safeGetProfile(playerID)
	if not profile then
		return false, errorMsg
	end

	local success, result = pcall(callback, profile)
	if not success then
		warn("[Economy] Profile operation failed: " .. tostring(result))
		return false, "Internal error"
	end

	return true, result
end

local function scheduleAutoSave()
	while true do
		task.wait(autoSaveInterval)
		for playerID, profile in pairs(profiles) do
			if profile and profile.Data then
				-- Don't yield the thread, just spawn the save
				task.spawn(function()
					local success, err = pcall(function()
						profile:Save()
					end)
					if not success and RunService:IsStudio() then
						warn("[Economy] Auto-save failed for player " .. playerID .. ": " .. tostring(err))
					end
				end)
			end
		end
	end
end

-- Initialize player profile on join with improved error handling (PascalCase for event handlers)
local function PlayerAdded(player)
	local playerID = player.UserId

	-- If profile is already loaded, don't load it again
	if profiles[playerID] then
		warn("[Economy] Profile already loaded for player " .. playerID)
		return
	end

	-- Set up a loading lock to prevent duplicate loads
	if transactionLocks[playerID] then
		warn("[Economy] Profile is already being loaded for player " .. playerID)
		return
	end

	transactionLocks[playerID] = true

	local profile
	local success, errorMsg = pcall(function()
		profile = ProfileStore:LoadProfileAsync("Player_" .. playerID)
	end)

	-- Release the loading lock
	transactionLocks[playerID] = nil

	if not success then
		warn("[Economy] Failed to load profile for player " .. playerID .. ": " .. tostring(errorMsg))
		if player:IsDescendantOf(Players) then
			player:Kick("Failed to load your data. Please rejoin.")
		end
		return
	end

	if profile ~= nil then
		profile:AddUserId(playerID) -- GDPR compliance
		profile:Reconcile() -- Fill in missing data with template

		if player:IsDescendantOf(Players) then
			profiles[playerID] = profile

			-- Set up profile release on leave
			profile:ListenToRelease(function()
				profiles[playerID] = nil
				-- If the player is still in game, kick them
				if player:IsDescendantOf(Players) then
					player:Kick("Your data was loaded on another server. Please rejoin.")
				end
			end)

			-- Clean up old receipts
			cleanupOldReceipts(profile)
		else
			-- Player left before profile loaded
			profile:Release()
		end
	else
		-- This happens if the profile is locked (being used by another server)
		if player:IsDescendantOf(Players) then
			player:Kick("Your data is currently in use on another server. Please try again later.")
		end
	end
end

local function PlayerRemoving(player)
	local profile = profiles[player.UserId]
	if profile then
		-- Clean up any pending transactions for this player
		if pendingTransactions[player.UserId] then
			pendingTransactions[player.UserId] = nil
		end

		-- Save before releasing
		pcall(function()
			profile:Save()
		end)

		profile:Release()
		profiles[player.UserId] = nil
	end

	-- Clean up transaction locks
	transactionLocks[player.UserId] = nil
end

-- Currency Functions
local function InitializeCurrency(currencyName, currencyData)
	-- PascalCase for methods, camelCase for variables and fields

	-- Get the current value with validation
	function currencyData:GetValue(playerID)
		local success, result = safeProfileOperation(playerID, function(profile)
			local value = profile.Data.currencies[self.saveKey]

			-- Initialize if missing
			if value == nil then
				value = self.defaultValue
				profile.Data.currencies[self.saveKey] = value
			end

			-- Validate the value
			if not isValidNumber(value) then
				warn("[Economy] Invalid currency value for " .. playerID .. ", " .. self.saveKey .. ": " .. tostring(value))
				value = self.defaultValue
				profile.Data.currencies[self.saveKey] = value
			end

			-- Clamp to valid range
			value = math.clamp(value, self.minValue, self.maxValue)
			profile.Data.currencies[self.saveKey] = value

			return value
		end)

		return success and result or self.defaultValue, success
	end

	-- Set the currency value with validation
	function currencyData:SetValue(playerID, value)
		if not isValidNumber(value) then
			return false, "Invalid value"
		end

		-- Instead of dropping the transaction, wait until any active transaction completes.
		while transactionLocks[playerID] do
			task.wait(0.05)
		end
		transactionLocks[playerID] = true

		local success, result = safeProfileOperation(playerID, function(profile)
			local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue

			-- Clamp to valid range
			value = math.clamp(value, self.minValue, self.maxValue)

			-- Save the transaction
			local transactionInfo = {
				transactionId = generateTransactionID(),
				timestamp = os.time(),
				playerID = playerID,
				currencyKey = self.saveKey,
				previousValue = currentValue,
				newValue = value,
				changeAmount = value - currentValue,
				reason = "SetValue"
			}

			-- Update the value
			profile.Data.currencies[self.saveKey] = value

			-- Log the transaction
			logTransaction(transactionInfo)

			return true
		end)

		transactionLocks[playerID] = nil

		return success, not success and result or nil
	end

	-- Increment the currency value
	function currencyData:IncrementValue(playerID, amount, reason)
		if not isValidNumber(amount) then
			return false, "Invalid amount"
		end

		while transactionLocks[playerID] do
			task.wait(0.05)
		end
		transactionLocks[playerID] = true

		local success, result = safeProfileOperation(playerID, function(profile)
			local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
			if not isValidNumber(currentValue) then
				currentValue = self.defaultValue
			end

			local newValue = currentValue + amount

			-- Clamp to valid range
			newValue = math.clamp(newValue, self.minValue, self.maxValue)

			-- Save the transaction
			local transactionInfo = {
				transactionId = generateTransactionID(),
				timestamp = os.time(),
				playerID = playerID,
				currencyKey = self.saveKey,
				previousValue = currentValue,
				newValue = newValue,
				changeAmount = amount,
				reason = reason or "IncrementValue"
			}

			-- Update the value
			profile.Data.currencies[self.saveKey] = newValue

			-- Log the transaction
			logTransaction(transactionInfo)

			return true
		end)

		transactionLocks[playerID] = nil

		return success, not success and result or nil
	end

	-- Decrement the currency value
	function currencyData:DecrementValue(playerID, amount, reason)
		if not isValidNumber(amount) or amount < 0 then
			return false, "Invalid amount"
		end

		return self:IncrementValue(playerID, -amount, reason or "DecrementValue")
	end

	-- Transfer currency between players
	function currencyData:TransferValue(fromPlayerID, toPlayerID, amount, reason)
		if not isValidNumber(amount) or amount <= 0 then
			return false, "Invalid amount"
		end

		if fromPlayerID == toPlayerID then
			return false, "Cannot transfer to same player"
		end

		-- First check if sender has enough
		local currentValue, success = self:GetValue(fromPlayerID)
		if not success then
			return false, "Failed to get sender's currency"
		end

		if currentValue < amount then
			return false, "Insufficient funds"
		end

		-- Wait until both players are free from other transactions.
		while transactionLocks[fromPlayerID] or transactionLocks[toPlayerID] do
			task.wait(0.05)
		end
		transactionLocks[fromPlayerID] = true
		transactionLocks[toPlayerID] = true

		-- Decrement sender
		local success1, error1 = safeProfileOperation(fromPlayerID, function(profile)
			local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
			local newValue = math.clamp(currentValue - amount, self.minValue, self.maxValue)
			local transactionInfo = {
				transactionId = generateTransactionID(),
				timestamp = os.time(),
				playerID = fromPlayerID,
				currencyKey = self.saveKey,
				previousValue = currentValue,
				newValue = newValue,
				changeAmount = -amount,
				reason = reason or "TransferSent"
			}
			profile.Data.currencies[self.saveKey] = newValue
			logTransaction(transactionInfo)
			return true
		end)
		if not success1 then
			transactionLocks[fromPlayerID] = nil
			transactionLocks[toPlayerID] = nil
			return false, "Failed to decrement sender: " .. (error1 or "Unknown error")
		end

		-- Increment receiver
		local success2, error2 = safeProfileOperation(toPlayerID, function(profile)
			local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
			local newValue = math.clamp(currentValue + amount, self.minValue, self.maxValue)
			local transactionInfo = {
				transactionId = generateTransactionID(),
				timestamp = os.time(),
				playerID = toPlayerID,
				currencyKey = self.saveKey,
				previousValue = currentValue,
				newValue = newValue,
				changeAmount = amount,
				reason = reason or "TransferReceived"
			}
			profile.Data.currencies[self.saveKey] = newValue
			logTransaction(transactionInfo)
			return true
		end)

		transactionLocks[fromPlayerID] = nil
		transactionLocks[toPlayerID] = nil

		if not success2 then
			-- Rollback sender's transaction
			safeProfileOperation(fromPlayerID, function(profile)
				local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
				local rollbackValue = math.clamp(currentValue + amount, self.minValue, self.maxValue)
				profile.Data.currencies[self.saveKey] = rollbackValue
				logTransaction({
					transactionId = generateTransactionID(),
					timestamp = os.time(),
					playerID = fromPlayerID,
					currencyKey = self.saveKey,
					previousValue = currentValue,
					newValue = rollbackValue,
					changeAmount = amount,
					reason = "TransferRollback"
				})
				return true
			end)
			return false, "Failed to increment receiver: " .. (error2 or "Unknown error")
		end

		return true
	end
end

-- Initialize each currency
for currencyName, currencyData in pairs(Currencies) do
	InitializeCurrency(currencyName, currencyData)
end

-- Purchase and Receipt Processing (PascalCase for public API methods)

-- Enhanced purchase function with better Studio handling
function Economy.PurchaseCurrencyAsync(player, currencyName, currencyAmount)
	if not player or not player:IsA("Player") then
		return false, "Invalid player"
	end

	local currency = Currencies[currencyName]
	if not currency then 
		return false, "Invalid currency: " .. tostring(currencyName)
	end

	if not currency.canBePurchased then
		return false, "Currency cannot be purchased: " .. tostring(currencyName)
	end

	-- Validate currency amount
	if not isValidNumber(currencyAmount) or currencyAmount <= 0 then
		return false, "Invalid amount"
	end

	-- Ensure that the currency has a purchaseIDs table and the amount is valid
	if not currency.purchaseIDs or not currency.purchaseIDs[currencyAmount] then
		return false, "No valid Purchase ID found for currency: " .. currencyName .. ", amount: " .. currencyAmount
	end

	local purchaseID = currency.purchaseIDs[currencyAmount]

	-- Special handling for Studio
	if RunService:IsStudio() then
		print("[Economy] Studio environment detected - simulating purchase for " .. currencyName .. ", amount: " .. currencyAmount)

		-- Directly simulate a successful purchase in Studio by creating a mock receipt
		local mockReceipt = {
			PlayerId = player.UserId,
			ProductId = purchaseID,
			ReceiptId = "STUDIO_" .. HttpService:GenerateGUID(false)
		}

		-- Process the mock receipt directly
		Economy.ProcessReceipt(mockReceipt)
		return true
	end

	-- Production environment - prompt real purchase
	local success, errorMessage = pcall(function()
		MarketplaceService:PromptProductPurchase(player, purchaseID)
	end)

	if not success then
		warn("[Economy] Error prompting product purchase: " .. errorMessage)
		return false, "Failed to prompt purchase"
	end

	-- Note: We don't grant currency here - that happens in ProcessReceipt
	return true
end

-- Get a list of all available purchasable currency amounts
function Economy.GetPurchaseOptions(currencyName)
	local currency = Currencies[currencyName]
	if not currency or not currency.canBePurchased then 
		return {}
	end

	local options = {}
	for amount, productId in pairs(currency.purchaseIDs) do
		table.insert(options, {
			amount = amount,
			productId = productId
		})
	end

	-- Sort by amount
	table.sort(options, function(a, b)
		return a.amount < b.amount
	end)

	return options
end

-- Public API functions
function Economy.GetCurrency(currencyName)
	return Currencies[currencyName]
end

function Economy.GetAllCurrencies()
	local result = {}
	for name, currency in pairs(Currencies) do
		result[name] = currency
	end
	return result
end

function Economy.GetPlayerCurrencies(playerID)
	local result = {}
	for name, currency in pairs(Currencies) do
		result[name] = currency:GetValue(playerID)
	end
	return result
end

-- ProcessReceipt Callback with improved Studio handling and idempotency
function Economy.ProcessReceipt(receiptInfo)
	-- Enhanced Studio testing mode
	if RunService:IsStudio() then
		-- Always grant purchases in Studio without requiring receipts
		print("[Economy] Auto-granting purchase in Studio environment for Product ID:", receiptInfo.ProductId)

		-- Get the player (if available)
		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if player then
			-- Get mapping information for the product
			local mapping = developerProductMapping[receiptInfo.ProductId]
			if mapping then
				-- Directly grant the currency in Studio mode
				local currency = mapping.currencyData
				local success, errorMsg = currency:IncrementValue(
					receiptInfo.PlayerId,
					mapping.amount,
					"StudioPurchase_" .. (receiptInfo.ReceiptId or HttpService:GenerateGUID(false))
				)

				if not success then
					warn("[Economy] Failed to grant currency in Studio: " .. (errorMsg or "Unknown error"))
				end
			else
				warn("[Economy] Unknown developer product ID in Studio: " .. tostring(receiptInfo.ProductId))
			end
		end

		-- Always grant purchases in Studio
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Production environment logic follows
	-- Check if ReceiptId is valid (this can still occur in production)
	if not receiptInfo.ReceiptId then
		warn("[Economy] ReceiptId is nil. This should not happen in production.")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Check if we're already processing this receipt (prevents race conditions)
	if receiptProcessingMap[receiptInfo.ReceiptId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Mark receipt as being processed
	receiptProcessingMap[receiptInfo.ReceiptId] = true

	-- Get player
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- Player left the game
		receiptProcessingMap[receiptInfo.ReceiptId] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Get profile
	local profile, errorMsg = safeGetProfile(receiptInfo.PlayerId)
	if not profile then
		-- Profile not loaded yet
		receiptProcessingMap[receiptInfo.ReceiptId] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Check if this receipt was already processed (idempotency check)
	if profile.Data.processedReceipts[receiptInfo.ReceiptId] then
		receiptProcessingMap[receiptInfo.ReceiptId] = nil
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Check if the product is valid
	local mapping = developerProductMapping[receiptInfo.ProductId]
	if not mapping then
		warn("[Economy] Unknown developer product ID: " .. tostring(receiptInfo.ProductId))
		receiptProcessingMap[receiptInfo.ReceiptId] = nil
		return Enum.ProductPurchaseDecision.PurchaseGranted -- Still grant it to avoid charging issues
	end

	-- Grant the currency
	local currency = mapping.currencyData
	local success, errorMsg = currency:IncrementValue(
		receiptInfo.PlayerId, 
		mapping.amount, 
		"Purchase_" .. receiptInfo.ReceiptId
	)

	if not success then
		warn("[Economy] Failed to grant currency for receipt " .. receiptInfo.ReceiptId .. ": " .. (errorMsg or "Unknown error"))
		receiptProcessingMap[receiptInfo.ReceiptId] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Mark receipt as processed with timestamp
	profile.Data.processedReceipts[receiptInfo.ReceiptId] = os.time()

	-- Save the profile immediately for purchases
	local saveSuccess, saveError = pcall(function()
		profile:Save()
	end)

	if not saveSuccess then
		warn("[Economy] Failed to save profile after purchase: " .. (saveError or "Unknown error"))
	end

	receiptProcessingMap[receiptInfo.ReceiptId] = nil
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Register event handlers
Players.PlayerAdded:Connect(PlayerAdded)
Players.PlayerRemoving:Connect(PlayerRemoving)

-- Process existing players
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(PlayerAdded, player)
end

-- Start auto-save task
task.spawn(scheduleAutoSave)

-- Register the ProcessReceipt callback
MarketplaceService.ProcessReceipt = Economy.ProcessReceipt

return Economy
