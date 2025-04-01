local MarketplaceService = game:GetService("MarketplaceService")
local ProfileService = require(script.Parent.ProfileService)
local Economy = {}

export type CurrencyData = {
	DisplayName: string,
	Abbreviation: string,
	SaveKey: string,
	CanBePurchased: boolean,
	CanBeEarned: boolean,
	ExchangeRateToRobux: number,
	DefaultValue: number,
	PurchaseIDs: {[number]: number} -- Amount of currency: Purchase ID
}

export type Currency = CurrencyData & {
	SetValue: (Currency, playerID: number, value: any) -> (),
	GetValue: (Currency, playerID: number) -> any,
	IncrementValue: (Currency, playerID: number, amount: number) -> ()
}

local Currencies = {
	Cash = {
		DisplayName = "Cash",
		Abbreviation = "$",
		SaveKey = "Cash",
		CanBePurchased = true,
		CanBeEarned = true,
		ExchangeRateToRobux = 10_000,
		DefaultValue = 1000,
		PurchaseIDs = {
			[100] = 3253924294
		}
	},
	Gems = {
		DisplayName = "Gems",
		Abbreviation = "💎",
		SaveKey = "Gems",
		CanBePurchased = true,
		CanBeEarned = false,
		ExchangeRateToRobux = 100,
		DefaultValue = 100
	}
}

-- Setup ProfileService
local ProfileStore = ProfileService.GetProfileStore(
	"PlayerEconomy1",
	{
		Currencies = {}
	}
)

local Profiles = {}

-- Handle player joining and initialize their profile
local function PlayerAdded(player)
	local profile = ProfileStore:LoadProfileAsync("Player_" .. player.UserId)

	if profile ~= nil then
		profile:AddUserId(player.UserId) -- GDPR compliance
		profile:Reconcile() -- Fill in missing data

		if player:IsDescendantOf(game.Players) then
			Profiles[player.UserId] = profile
			-- Initialize currency data if doesn't exist
			if not profile.Data.Currencies then
				profile.Data.Currencies = {}
			end
		else
			profile:Release() -- Player left before profile loaded
		end
	else
		-- Failed to load profile
		player:Kick("Failed to load your data. Please rejoin.")
	end
end

-- Handle player leaving and release their profile
local function PlayerRemoving(player)
	local profile = Profiles[player.UserId]
	if profile then
		profile:Release()
		Profiles[player.UserId] = nil
	end
end

-- Connect player events when the game starts
game.Players.PlayerAdded:Connect(PlayerAdded)
game.Players.PlayerRemoving:Connect(PlayerRemoving)

-- Initialize existing players
for _, player in ipairs(game.Players:GetPlayers()) do
	task.spawn(PlayerAdded, player)
end
-- Get a specific currency by name
function Economy.GetCurrency(currencyName: string): Currency?
	return Currencies[currencyName]
end

-- Purchase currency with Robux
function Economy.PurchaseCurrency(player: Player, currencyName: string, currencyAmount: number): boolean
	local currency = Currencies[currencyName]
	if not currency or not currency.CanBePurchased then return false end
	
	local purchaseID = currency.PurchaseIDs[currencyAmount]
	
	local success, errorMessage = pcall(function()
		if not purchaseID then error("No Purchase ID") end
		MarketplaceService:PromptProductPurchase(player, purchaseID)
		local completed = false
		local itemBought = false
		local event = MarketplaceService.PromptProductPurchaseFinished
		event:Connect(function(userID, productID, isPurchased)
			itemBought = ((userID == player.UserId) and (productID == purchaseID) and isPurchased)
			completed = true
		end)
		print("Processing")
		repeat task.wait() until completed
		print("Processed")
		if not itemBought then error("Purchase Failed Or Player Did Not Buy Item") end
	end)

	if success then
		currency:IncrementValue(player.UserId, currencyAmount)
		Profiles[player.UserId]:Save()
		print(currency:GetValue(player.UserId))
		return true
	else
		warn(errorMessage)
	end

	return false
end

local function InitializeCurrency(currencyData)
	-- Get currency value from player profile
	function currencyData:GetValue(playerID: number)
		local profile = Profiles[playerID]
		if not profile then return 0 end

		if not profile.Data.Currencies[self.SaveKey] then
			profile.Data.Currencies[self.SaveKey] = self.DefaultValue
			return self.DefaultValue
		end

		return profile.Data.Currencies[self.SaveKey]
	end

	-- Set currency value and save to profile
	function currencyData:SetValue(playerID: number, value: any)
		local profile = Profiles[playerID]
		if not profile then return end

		profile.Data.Currencies[self.SaveKey] = value
	end

	-- Increment currency value by amount
	function currencyData:IncrementValue(playerID: number, amount: number)
		local profile = Profiles[playerID]
		if not profile then return end

		if not profile.Data.Currencies[self.SaveKey] then
			profile.Data.Currencies[self.SaveKey] = self.DefaultValue
		end
		
		profile.Data.Currencies[self.SaveKey] += amount
	end
end

for _,CurrencyData: CurrencyData in pairs(Currencies) do
	InitializeCurrency(CurrencyData)
end

return Economy
