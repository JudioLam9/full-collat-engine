// SPDX-License-Identifier: Unlicense
pragma solidity =0.8.13;

import {OptionToken} from "./OptionToken.sol";

import {IMarginAccount} from "../interfaces/IMarginAccount.sol";
import {IERC20} from "../interfaces/IERC20.sol";

import {OptionTokenUtils} from "src/libraries/OptionTokenUtils.sol";
import {MarginMathLib} from "src/libraries/MarginMathLib.sol";
import {MarginAccountLib} from "src/libraries/MarginAccountLib.sol";

import "src/types/MarginAccountTypes.sol";
import {TokenType} from "src/constants/TokenEnums.sol";
import "src/constants/MarginAccountConstants.sol";

import "forge-std/console2.sol";

contract MarginAccount is IMarginAccount, OptionToken {
    using MarginMathLib for MarginAccountDetail;

    using MarginAccountLib for Account;

    /*///////////////////////////////////////////////////////////////
                                  Variables
    //////////////////////////////////////////////////////////////*/

    ///@dev accountId => Account.
    ///     accountId can be an address similar to the primary account, but has the last 8 bits different.
    ///     this give every account access to 256 sub-accounts
    mapping(address => Account) public marginAccounts;

    ///@dev primaryAccountId => operator => authorized
    ///     every account can authorize any amount of addresses to modify all accounts he controls.
    mapping(uint160 => mapping(address => bool)) public authorized;

    // mocked
    uint256 public spotPrice = 3000 * UNIT;

    function getMinCollateral(address _accountId) external view returns (uint256 minCollateral) {
        Account memory account = marginAccounts[_accountId];
        MarginAccountDetail memory detail = _getAccountDetail(account);

        minCollateral = detail.getMinCollateral(spotPrice, 1000);
    }

    ///@dev need to be reentry-guarded
    function execute(address _accountId, ActionArgs[] calldata actions) external {
        _assertCallerHasAccess(_accountId);
        Account memory account = marginAccounts[_accountId];

        // update the account memory and do external calls on the flight
        for (uint256 i; i < actions.length; ) {
            if (actions[i].action == ActionType.AddCollateral) _addCollateral(account, actions[i].data, _accountId);
            else if (actions[i].action == ActionType.RemoveCollateral) _removeCollateral(account, actions[i].data);
            else if (actions[i].action == ActionType.MintShort) _mint(account, actions[i].data);

            // increase i without checking overflow
            unchecked {
                i++;
            }
        }
        _assertAccountHealth(account);
        marginAccounts[_accountId] = account;
    }

    function _addCollateral(Account memory _account, bytes memory _data, address accountId) internal {
        // decode parameters
        (address collateral, address from, uint256 amount) = abi.decode(_data, (address, address, uint256));
        
        // update the account structure in memory
        _account.addCollateral(collateral, amount);

        // collateral must come from caller or the primary account for this accountId
        if (from != msg.sender && !_isPrimaryAccountFor(from, accountId)) revert InvalidFromAddress(); 
        IERC20(collateral).transferFrom(from, address(this), amount);
    }

    function _removeCollateral(Account memory _account, bytes memory _data) internal {
        // decode parameters
        (uint256 amount, address recipient) = abi.decode(_data, (uint256, address));
        address collateral = _account.collateral;

        // update the account structure in memory
        _account.removeCollateral(amount);

        // external calls
        IERC20(collateral).transfer(recipient, amount);
    }

    function _mint(Account memory _account, bytes memory _data) internal {
        (uint256 tokenId, address recipient, uint256 amount) = abi.decode(_data, (uint256, address, uint256));
        _account.mintOption(tokenId, amount);

        // mint the real option token
        _mint(recipient, tokenId, amount, "");
    }

    function burn(
        address _account,
        uint256 _tokenId,
        uint256 _amount
    ) external {}

    // function settleAccount(address _account) external {}

    /// @dev add a ERC1155 long token into the margin account to reduce required collateral
    // function merge() external {}

    function _isPrimaryAccountFor(address _account, address _accountId) internal pure returns (bool) {
        return (uint160(_account) | 0xFF) == (uint160(_accountId) | 0xFF);
    }

    function _assertCallerHasAccess(address _accountId) internal view {
        if (_isPrimaryAccountFor(msg.sender, _accountId)) return;
        // the sender is not the direct owner. check if he's authorized
        uint160 primaryAccountId = (uint160(_accountId) | 0xFF);
        if (!authorized[primaryAccountId][msg.sender]) revert NoAccess();
    }

    function _assertAccountHealth(Account memory account) internal view {
        MarginAccountDetail memory detail = _getAccountDetail(account);

        uint256 minCollateral = detail.getMinCollateral(spotPrice, SHOCK_RATIO);

        if (account.collateralAmount < minCollateral) revert AccountUnderwater();
    }

    /// @dev convert Account struct from storage to in-memory detail struct
    function _getAccountDetail(Account memory account) internal pure returns (MarginAccountDetail memory detail) {
        detail = MarginAccountDetail({
            putAmount: account.shortPutAmount,
            callAmount: account.shortCallAmount,
            longPutStrike: 0,
            shortPutStrike: 0,
            longCallStrike: 0,
            shortCallStrike: 0,
            expiry: 0,
            collateralAmount: account.collateralAmount,
            isStrikeCollateral: false
        });

        // if it contains a call
        if (account.shortCallId != 0) {
            (, , , uint64 longStrike, uint64 shortStrike) = OptionTokenUtils.parseTokenId(account.shortCallId);
            detail.longCallStrike = longStrike;
            detail.shortCallStrike = shortStrike;
        }

        // if it contains a put
        if (account.shortPutId != 0) {
            (, , , uint64 longStrike, uint64 shortStrike) = OptionTokenUtils.parseTokenId(account.shortPutId);
            detail.longPutStrike = longStrike;
            detail.shortPutStrike = shortStrike;
        }

        // parse common field
        // use the OR operator, so as long as one of shortPutId or shortCallId is non-zero, got reflected here
        uint256 commonId = account.shortPutId | account.shortCallId;

        (, uint32 productId, uint64 expiry, , ) = OptionTokenUtils.parseTokenId(commonId);
        detail.isStrikeCollateral = OptionTokenUtils.productIsStrikeCollateral(productId);
        detail.expiry = expiry;
    }
}
