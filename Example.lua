local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

local Economy = require(ServerStorage.Economy)

-- Utility to print player balances
local function printBalance(player)
	local cash = Economy.GetCurrency("Cash")
	if not cash then return end
	
	local amount = cash:GetValue(player.UserId)
	print(string.format("%s has %d cash", player.Name, amount))
end

-- Handle new players
local function handleNewPlayer(player)
	-- Give the data system time to init
	task.wait(2)
	
	local cash = Economy.GetCurrency("Cash")
	if not cash then return end
	
	local startingBalance = cash:GetValue(player.UserId)
	print(string.format("%s joined with %d cash", player.Name, startingBalance))
	
	-- New player bonus
	if startingBalance == 0 then
		cash:SetValue(player.UserId, 100)
		print(string.format("Gave %s 100 starting cash!", player.Name))
		printBalance(player)
	end
end

-- Reward active players
local function giveRewards()
	local cash = Economy.GetCurrency("Cash")
	local gems = Economy.GetCurrency("Gems")
	if not cash or not gems then return end
	
	for _, player in ipairs(Players:GetPlayers()) do
		local oldCash = cash:GetValue(player.UserId)
		local oldGems = gems:GetValue(player.UserId)
		
		cash:IncrementValue(player.UserId, 10)
		gems:IncrementValue(player.UserId, 1)
		
		-- Log rewards
		print(string.format("%s: %d -> %d cash (+10)", player.Name, oldCash, oldCash + 10))
		print(string.format("%s: %d -> %d gems (+1)", player.Name, oldGems, oldGems + 1))
	end
end

Players.PlayerAdded:Connect(handleNewPlayer)
Players.PlayerRemoving:Connect(function(player)
	printBalance(player)
	print(player.Name .. " left")
end)

-- Main reward loop
task.wait(2) -- Initial delay
while true do
	task.wait(0.2)
	print("🎁 Giving out rewards...")
	giveRewards()
	
	print("\n💰 Current Balances:")
	for _, player in ipairs(Players:GetPlayers()) do
		printBalance(player)
	end
	print("-------------------")
end
