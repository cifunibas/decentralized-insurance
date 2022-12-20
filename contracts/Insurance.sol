// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "./Tranche.sol";
import "./ITranche.sol";

interface IAaveLendingpool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IcDAI is IERC20 {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
}

/*
For variable descriptions, see paper.
c = Dai (Maker DAI)
x = Aave protocol (cx = aDAI)
y = Compound protocol (cy = cDAI)
*/

/// @title SplitInsurance - A decentralized DeFi insurance protocol
/// @author Matthias Nadler, Felix Bekemeier, Fabian Schär
/// @notice Deposited funds are invested into Aave and Compound.
///         Redeeming rights are split into two tranches with different seniority
contract SplitInsurance {
    /* Internal and external contract addresses  */
    address public A; // Tranche A token contract
    address public B; // Tranche A token contract

    address public  c = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // Maker DAI token
    address public  x = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9; // Aave v2 lending pool
    address public cx = 0x028171bCA77440897B824Ca71D1c56caC55b68A3; // Aave v2 interest bearing DAI (aDAI)
    address public cy = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643; // Compound interest bearing DAI (cDAI)

    /* Math helper for decimal numbers */
    uint256 constant RAY = 1e27; // Used for floating point math

    /*
      Time controls
      - UNIX timestamps
      - Can be defined globally (here) or relative to deployment time (constructor)
    */
    uint256 public immutable S;
    uint256 public immutable T1;
    uint256 public immutable T2;
    uint256 public immutable T3;

    /* State tracking */
    uint256 public totalTranches; // Total A + B tokens
    bool public isInvested; // True if c has been deposited for cx and cy
    bool public inLiquidMode; // True: distribute c , False: xc/cy tokens claimable

    /* Liquid mode */
    uint256 public cPayoutA; // Payout in c tokens per A tranche, after dividing by RAY
    uint256 public cPayoutB; // Payout in c tokens per B tranche, after dividing by RAY

    /* Fallback mode */
    uint256 public cxPayout; // Payout in cx tokens per (A or B) tranche, after dividing by RAY
    uint256 public cyPayout; // Payout in cy tokens per (A or B) tranche, after dividing by RAY

    /* Events */
    event RiskSplit(address indexed splitter, uint256 amount_c);
    event Invest(uint256 amount_c, uint256 amount_cx, uint256 amount_cy, uint256 amount_c_incentive);
    event Divest(uint256 amount_c, uint256 amount_cx, uint256 amount_cy, uint256 amount_c_incentive);
    event Claim(address indexed claimant, uint256 amount_A, uint256 amount_B, uint256 amount_c, uint256 amount_cx, uint256 amount_cy);


    constructor () {
        A = address(new Tranche("Tranche A", "A"));
        B = address(new Tranche("Tranche B", "B"));
        S = block.timestamp + 3600 * 24 * 7; // +7 days
        T1 = S + 3600 * 24 * 28; // +28 days
        T2 = T1 + 3600 * 24 * 1; // +1 day
        T3 = T2 + 3600 * 24 * 3; // +3days
    }

    /// @notice Deposit Dai into the protocol. Receive equal amounts of A and B tranches.
    /// @dev    Requires approval for Dai
    /// @param  amount_c The amount of Dai to invest into the protocol
    function splitRisk(uint256 amount_c) public {
        require(block.timestamp < S, "split: no longer in issuance period");
        require(amount_c > 1, "split: amount_c too low");

        if (amount_c % 2 != 0) {
            // Only accept even denominations
            amount_c -= 1;
        }

        require(
            IERC20(c).transferFrom(msg.sender, address(this), amount_c),
            "split: failed to transfer c tokens"
        );

        ITranche(A).mint(msg.sender, amount_c / 2);
        ITranche(B).mint(msg.sender, amount_c / 2);

        emit RiskSplit(msg.sender, amount_c);
    }

    /// @notice Invest all deposited funds into Aave and Compound, 50:50
    /// @dev  Should be incentivized for the first successful call
    function invest() public {
        require(!isInvested, "split: investment was already performed");
        require(block.timestamp >= S, "split: still in issuance period");
        require(block.timestamp < T1, "split: no longer in insurance period");

        address me = address(this);
        IERC20 cToken = IERC20(c);
        uint256 balance_c = cToken.balanceOf(me);
        require(balance_c > 0, "split: no c tokens found");
        totalTranches = ITranche(A).totalSupply() * 2;

        // Protocol X: Aave
        cToken.approve(x, balance_c / 2);
        IAaveLendingpool(x).deposit(c, balance_c / 2, me, 0);

        // Protocol Y: Compound
        require(
            IcDAI(cy).mint(balance_c / 2) == 0,
            "split: error while minting cDai"
        );

        isInvested = true;
        emit Invest(balance_c, IERC20(cx).balanceOf(me), IERC20(cy).balanceOf(me), 0);
    }

    /// @notice Attempt to withdraw all funds from Aave and Compound.
    ///         Then calculate the redeem ratios, or enter fallback mode
    /// @dev    Should be incentivized for the first successful call
    function divest() public {
        // Should be incentivized on the first successful call
        require(block.timestamp >= T1, "split: still in insurance period");
        require(block.timestamp < T2, "split: already in claim period");

        IERC20 cToken  = IERC20(c);
        IERC20 cxToken = IERC20(cx);
        IcDAI  cyToken = IcDAI(cy);
        address me = address(this);

        uint256 halfOfTranches = totalTranches / 2;
        uint256 balance_cx =  cxToken.balanceOf(me);
        uint256 balance_cy =  cyToken.balanceOf(me);
        require (balance_cx > 0 && balance_cy > 0, "split: unable to redeem tokens");
        uint256 interest;

        // Protocol X: Aave
        uint256 balance_c = cToken.balanceOf(me);
        IAaveLendingpool(x).withdraw(c, balance_cx, me);
        uint256 withdrawn_x = cToken.balanceOf(me) - balance_c;
        if (withdrawn_x > halfOfTranches) {
            interest += withdrawn_x - halfOfTranches;
        }

        // Protocol Y: Compound
        require(
            cyToken.redeem(balance_cy) == 0,
            "split: unable to redeem cDai"
        );
        uint256 withdrawn_y = cToken.balanceOf(me) - balance_c - withdrawn_x;
        if (withdrawn_y > halfOfTranches) {
            interest += withdrawn_y - halfOfTranches;
        }

        require(cxToken.balanceOf(me) == 0 && cyToken.balanceOf(me) == 0, "split: Error while redeeming tokens");

        // Determine payouts
        inLiquidMode = true;
        balance_c = cToken.balanceOf(me);
        if (balance_c >= totalTranches) {
            // No losses, equal split of all c among A/B shares
            cPayoutA = RAY * balance_c / totalTranches;
            cPayoutB = cPayoutA;
        } else if (balance_c > halfOfTranches) {
            // Balance covers at least the investment of all A shares
            cPayoutA = RAY * interest / halfOfTranches + RAY; // A tranches fully covered and receive all interest
            cPayoutB = RAY * (balance_c - halfOfTranches - interest) / halfOfTranches;
        } else {
            // Greater or equal than 50% loss
            cPayoutA = RAY * balance_c / halfOfTranches; // Divide recovered assets among A
            cPayoutB = 0; // Not enough to cover B
        }

        emit Divest(balance_c, balance_cx, balance_cy, 0);
    }

    /// @notice Redeem A-tranches for aDai or cDai
    /// @dev    Only available in fallback mode
    /// @param  tranches_to_cx The amount of A-tranches that will be redeemed for aDai
    /// @param  tranches_to_cy The amount of A-tranches that will be redeemed for cDai
    function claimA(uint256 tranches_to_cx, uint256 tranches_to_cy) public {
        if(!isInvested && !inLiquidMode && block.timestamp >= T1) {
            // If invest was never called, activate liquid mode for redemption
            inLiquidMode = true;
        }
        if (inLiquidMode) {
            // Pay out c directly
            claim(tranches_to_cx + tranches_to_cy, 0);
            return;
        }
        require(block.timestamp >= T2, "split: claim period for A tranches not active yet");
        _claimFallback(tranches_to_cx, tranches_to_cy, A);
    }

    /// @notice Redeem B-tranches for aDai or cDai
    /// @dev    Only available in fallback mode, after A-tranches had a window to redeem
    /// @param  tranches_to_cx The amount of B-tranches that will be redeemed for aDai
    /// @param  tranches_to_cy The amount of B-tranches that will be redeemed for cDai
    function claimB(uint256 tranches_to_cx, uint256 tranches_to_cy) public {
        if(!isInvested && !inLiquidMode && block.timestamp >= T1) {
            // If invest was never called, activate liquid mode for redemption
            inLiquidMode = true;
        }
        if (inLiquidMode) {
            // Pay out c directly
            claim(0, tranches_to_cx + tranches_to_cy);
            return;
        }
        require(block.timestamp >= T3, "split: claim period for B tranches not active yet");
        _claimFallback(tranches_to_cx, tranches_to_cy, B);
    }

    function _claimFallback(uint256 tranches_to_cx, uint256 tranches_to_cy, address trancheAddress) internal {
        require(tranches_to_cx > 0 || tranches_to_cy > 0, "split: to_cx or to_cy must be greater than zero");

        ITranche tranche = ITranche(trancheAddress);
        require(tranche.balanceOf(msg.sender) >= tranches_to_cx + tranches_to_cy, "split: sender does not hold enough tranche tokens");

        uint256 amount_A;
        uint256 amount_B;
        if (trancheAddress == A) {
            amount_A = tranches_to_cx + tranches_to_cy;
        } else if (trancheAddress == B) {
            amount_B = tranches_to_cx + tranches_to_cy;
        }

        // Payouts
        uint256 payout_cx;
        uint256 payout_cy;
        if (tranches_to_cx > 0) {
            IERC20 cxToken = IERC20(cx);

            // Initialize cx split, only on first call
            if (cxPayout == 0) {
                cxPayout = RAY * cxToken.balanceOf(address(this)) / totalTranches / 2;
            }

            tranche.burn(msg.sender, tranches_to_cx);
            payout_cx = tranches_to_cx * cxPayout / RAY;
            cxToken.transfer(msg.sender, payout_cx);
        }

        if (tranches_to_cy > 0) {
            IERC20 cyToken = IERC20(cy);

            // Initialize cy split, only on first call
            if (cyPayout == 0) {
                cyPayout = RAY * cyToken.balanceOf(address(this)) / totalTranches / 2;
            }

            tranche.burn(msg.sender, tranches_to_cy);
            payout_cy =  tranches_to_cy * cyPayout / RAY;
            cyToken.transfer(msg.sender, payout_cy);
        }

        emit Claim(msg.sender, amount_A, amount_B, 0, payout_cx, payout_cy);
    }

    /// @notice Redeem **all** owned A- and B-tranches for Dai
    /// @dev    Only available in liquid mode
    function claimAll() public {
        uint256 balance_A = ITranche(A).balanceOf(msg.sender);
        uint256 balance_B = ITranche(B).balanceOf(msg.sender);
        require(balance_A > 0 || balance_B > 0, "split: insufficient tranche tokens");
        claim(balance_A, balance_B);
    }

    /// @notice Redeem A- and B-tranches for Dai
    /// @dev    Only available in liquid mode
    /// @param  amount_A The amount of A-tranches that will be redeemed for Dai
    /// @param  amount_B The amount of B-tranches that will be redeemed for Dai
    function claim(uint256 amount_A, uint256 amount_B) public {
        if (!inLiquidMode) {
            if(!isInvested && block.timestamp >= T1) {
                // If invest was never called, activate liquid mode for redemption
                inLiquidMode = true;
            } else {
                if (block.timestamp < T1) {
                    revert("split: can not claim during insurance period");
                } else if (block.timestamp < T2) {
                    revert("split: call divest() first");
                } else {
                    revert("split: use claimA() or claimB() instead");
                }
            }
        }
        require(amount_A > 0 || amount_B > 0, "split: amount_A or amount_B must be greater than zero");
        uint256 payout_c;

        if (amount_A > 0) {
            ITranche tranche_A = ITranche(A);
            require(tranche_A.balanceOf(msg.sender) >= amount_A, "split: insufficient tranche A tokens");
            tranche_A.burn(msg.sender, amount_A);
            payout_c += cPayoutA * amount_A / RAY;
        }

        if (amount_B > 0) {
            ITranche tranche_B = ITranche(B);
            require(tranche_B.balanceOf(msg.sender) >= amount_B, "split: insufficient tranche B tokens");
            tranche_B.burn(msg.sender, amount_B);
            payout_c += cPayoutB * amount_B / RAY;
        }

        if (payout_c > 0) {
            IERC20(c).transfer(msg.sender, payout_c);
        }

        emit Claim(msg.sender, amount_A, amount_B, payout_c, 0, 0);
    }

}
