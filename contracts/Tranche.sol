// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.0/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.0/contracts/access/Ownable.sol";

/// @title Tranche tokens for the SplitInsurance contract
/// @author Matthias Nadler, Felix Bekemeier, Fabian Schär
contract Tranche is ERC20, Ownable {

    constructor (string memory name_, string memory symbol_) ERC20(name_, symbol_) {
    }

    /// @notice Allows the owner to mint new tranche tokens
    /// @dev The insurance contract should be the immutable owner
    /// @param account The recipient of the new tokens
    /// @param amount The amount of new tokens to mint
    function mint(address account, uint256 amount) public onlyOwner {
        _mint(account, amount);
    }

    /// @notice Allows the owner to burn tranche tokens
    /// @dev The insurance contract should be the immutable owner
    /// @param account The owner of the tokens to be burned
    /// @param amount The amount of tokens to burn
    function burn(address account, uint256 amount) public onlyOwner {
        _burn(account, amount);
    }

}
