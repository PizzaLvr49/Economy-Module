# Economy-Tutorial

This repository contains the source code for an economy system tutorial for a Roblox game. The tutorial demonstrates how to create a simple economy system using the ProfileService module for handling player data and currency management.

## Table of Contents

- Installation
- Usage
- Features
- Contributing
- License

## Installation

To use the code in this repository, follow these steps:

1. Copy the files and paste them into studio put the module and ProfileService in ServerStorage

2. Open the Roblox Studio and navigate to your project.

3. Insert the Economy.lua and Example.lua files into the ServerStorage folder of your project.

4. Ensure that the ProfileService module is available in your project. You can find the ProfileService module here: https://devforum.roblox.com/t/profileservice-datastore-module/667805

## Usage

The following scripts are included in this repository:

- **Economy.lua**: This script defines the Economy module, which manages different types of currencies and player profiles.
- **Example.lua**: This script demonstrates how to use the Economy module to log player money, give starting cash to new players, and reward active players.

### Economy.lua

The Economy.lua script defines the Economy module and provides functions to manage player currencies. It includes the following features:

- **Currencies**: Defines different types of currencies, such as Cash and Gems.
- **Profile Management**: Uses ProfileService to manage player profiles and load/save currency data.
- **Currency Management**: Provides functions to set, get, and increment currency values for players.

### Example.lua

The Example.lua script demonstrates how to use the Economy module in a Roblox game. It includes the following features:

- **Player Join Handling**: Logs a player's money when they join and gives starting cash to new players.
- **Active Player Rewards**: Rewards active players with additional cash and gems periodically.
- **Player Events**: Connects to player join and leave events to manage player data.

## Features

- **Profile Management**: Uses ProfileService to handle player profiles and currency data.
- **Multiple Currencies**: Supports multiple types of currencies with different properties.
- **Currency Transactions**: Allows for setting, getting, and incrementing currency values for players.
- **Robux Transactions**: Provides a simplified example of purchasing currency with Robux.

## Contributing

Contributions are welcome! If you find any issues or have suggestions for improvements, please create an issue or submit a pull request.

## License

This project is licensed under the MIT License. See the LICENSE file for more details.
