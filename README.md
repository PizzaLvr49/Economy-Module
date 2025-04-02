# Economy Module

## Description
The Economy Module is a comprehensive economy system designed for Roblox games. This module allows developers to manage multiple types of currencies, handle player profiles, and process transactions with ease. It leverages the ProfileService module to ensure robust data management and persistence.

## Features
- **Profile Management**: Uses ProfileService to handle player profiles and currency data.
- **Multiple Currencies**: Supports multiple types of currencies with customizable properties.
- **Currency Transactions**: Allows for setting, getting, incrementing, decrementing, and transferring currency values for players.
- **Robux Transactions**: Simplifies purchasing currency with Robux.
- **Receipt Processing**: Ensures secure and reliable transaction processing.

## License
[MIT License](LICENSE)

## Installation
To use the Economy Module in your Roblox project, follow these steps:

1. Copy or download the source files from this repository.
2. Open Roblox Studio and navigate to your project.
3. Insert the `Economy.lua` file into the `ServerStorage` folder of your project.
4. Ensure that the ProfileService module is available in your project. You can find the ProfileService module [here](https://devforum.roblox.com/t/profileservice-datastore-module/667805).

## Usage
The `Economy.lua` script defines the Economy module and provides functions to manage player currencies. Here are the key functions:

### Usage

#### GetCurrency
Retrieve a currency by its name.
```lua
local currency = Economy.GetCurrency(currencyName)
```

#### GetAllCurrencies
Retrieve all defined currencies.
```lua
local currencies = Economy.GetAllCurrencies()
```

#### GetPlayerCurrencies
Retrieve all currency values for a specific player.
```lua
local playerCurrencies = Economy.GetPlayerCurrencies(playerID)
```

#### PurchaseCurrencyAsync
Prompt a player to purchase a specific amount of currency.
```lua
local success, message = Economy.PurchaseCurrencyAsync(player, currencyName, currencyAmount)
```

#### GetPurchaseOptions
Retrieve available purchase options for a currency.
```lua
local options = Economy.GetPurchaseOptions(currencyName)
```

#### ProcessReceipt
Process a purchase receipt.
```lua
MarketplaceService.ProcessReceipt = Economy.ProcessReceipt
```

### Tutorial

To get started using the Economy Module, follow these steps:

1. **Initial Setup**:
   - Ensure the `Economy.lua` script is placed in the `ServerStorage` folder.
   - Add the ProfileService module to your project.

2. **Defining Currencies**:
   - Use thee `Economy.CreateCurrency()` method.
   ```lua
   Economy.CreateCurrency("Cash", {
      displayName = "Cash",
      abbreviation = "$",
      saveKey = "cash",
      canBePurchased = true,
      canBeEarned = true,
      exchangeRateToRobux = 0.01,
      defaultValue = 0,
      minValue = 0,
      maxValue = 1000000,
      purchaseIDs = {
         [100] = {SKU = "cash100", ID = 123456}
      }
   })
   ```

3. **Using the Module**:
   - **Add the Economy Module**:
     ```lua
     local Economy = require(game.ServerStorage.Economy)
     ```

   - **Handling Player Join**:
     ```lua
     game.Players.PlayerAdded:Connect(function(player)
         print("Player joined:", player.Name)
         local playerCurrencies = Economy.GetPlayerCurrencies(player.UserId)
         print("Player currencies:", playerCurrencies)
     end)
     ```

   - **Handling Currency Transactions**:
     ```lua
     local cashCurrency = Economy.GetCurrency("Cash")
     local success, message = cashCurrency:SetValue(player.UserId, 1000, "Initial Cash Grant")
     if success then
         print("Currency set successfully!")
     else
         warn("Failed to set currency:", message)
     end
     ```

4. **Processing Purchases**:
   - **Prompting a Purchase**:
     ```lua
     local success, message = Economy.PurchaseCurrencyAsync(player, "Cash", 100)
     if success then
         print("Purchase prompted successfully!")
     else
         warn("Failed to prompt purchase:", message)
     end
     ```

   - **Handling Receipts**:
     ```lua
     MarketplaceService.ProcessReceipt = Economy.ProcessReceipt
     ```

## Support
For support, you can:
- Open an issue in this repository.
- Reach out via email at support@example.com.

## Roadmap
Future enhancements include:
- Adding support for more complex transaction types.
- Enhancing the receipt processing system.
- Integrating with other payment methods.

## Contributing
Contributions are welcome! If you find any issues or have suggestions for improvements, please create an issue or submit a pull request. To get started:
1. Fork this repository.
2. Create a new branch (`git checkout -b feature-branch`).
3. Make your changes.
4. Commit your changes (`git commit -m 'Add some feature'`).
5. Push to the branch (`git push origin feature-branch`).
6. Open a pull request.

## Authors and Acknowledgment
- **ExoticSliceOfPizza** - Main developer and maintainer of the Economy Module.

## License
This project is licensed under the MIT License. See the [LICENSE](https://github.com/PizzaLvr49/Economy-Module/blob/main/LICENSE) file for more details.

## Project Status
This project is actively maintained. However, contributions and new maintainers are always welcome.
