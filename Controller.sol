pragma solidity ^0.5.16;

/**
Copyright 2020 Compound Labs, Inc.
Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/**
* Original work from Compound: https://github.com/compound-finance/compound-protocol/blob/master/contracts/Comptroller.sol
* Modified to work in the Plutos Network.
* Main modifications:
*   1. removed Comp token related logics.
*   2. removed interest rate model related logics.
*   3. simplified calculations in mint, redeem, liquidity check, seize due to we don't use interest model/exchange rate.
*   4. user can only supply pTokens (see pToken) and borrow Plutos MCDs (see pMCD). Plutos MCD's underlying can be considered as itself.
*   5. removed error code propagation mechanism, using revert to fail fast and loudly.
*/

/**
 * @title Plutos's Controller Contract
 * @author Plutos
 */
contract Controller is ControllerStorage, PlutosControllerInterface, Exponential, ControllerErrorReporter {
    /// @notice Emitted when an admin supports a market
    event MarketListed(pToken pToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(pToken pToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(pToken pToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(pToken pToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(OracleInterface oldPriceOracle, OracleInterface newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(pToken pToken, string action, bool pauseState);

    /// @notice Emitted when borrow cap for a pToken is changed
    event NewBorrowCap(pToken indexed Token, uint newBorrowCap);

    /// @notice Emitted when supply cap for a pToken is changed
    event NewSupplyCap(pToken indexed pToken, uint newSupplyCap);

    /// @notice Emitted when borrow/supply cap guardian is changed
    event NewCapGuardian(address oldCapGuardian, address newCapGuardian);

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // liquidationIncentiveMantissa must be no less than this value
    uint internal constant liquidationIncentiveMinMantissa = 1.0e18; // 1.0

    // liquidationIncentiveMantissa must be no greater than this value
    uint internal constant liquidationIncentiveMaxMantissa = 1.5e18; // 1.5

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() public {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can call this function");
        _;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (pToken[] memory) {
        pToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param pToken The pToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, pToken pToken) external view returns (bool) {
        return markets[address(pToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param pTokens The list of addresses of the pToken markets to be enabled
     * @dev will revert if any market entering failed
     */
    function enterMarkets(address[] memory pTokens) public {
        uint len = pTokens.length;
        for (uint i = 0; i < len; i++) {
            pToken pToken = pToken(pTokens[i]);
            addToMarketInternal(pToken, msg.sender);
        }
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param pToken The market to enter
     * @param borrower The address of the account to modify
     */
    function addToMarketInternal(pToken pToken, address borrower) internal {
        Market storage marketToJoin = markets[address(pToken)];

        require(marketToJoin.isListed, MARKET_NOT_LISTED);

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(pToken);

        emit MarketEntered(pToken, borrower);
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param pTokenAddress The address of the asset to be removed
     */
    function exitMarket(address pTokenAddress) external {
        pToken pToken = pToken(pTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the pToken */
        (uint tokensHeld, uint amountOwed) = pToken.getAccountSnapshot(msg.sender);

        /* Fail if the sender has a borrow balance */
        require(amountOwed == 0, EXIT_MARKET_BALANCE_OWED);

        /* Fail if the sender is not permitted to redeem all of their tokens */
        (bool allowed,) = redeemAllowedInternal(pTokenAddress, msg.sender, tokensHeld);
        require(allowed, EXIT_MARKET_REJECTION);

        Market storage marketToExit = markets[address(pToken)];

        /* Succeed true if the sender is not already ???in??? the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return;
        }

        /* Set pToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete pToken from the account???s list of assets */
        // load into memory for faster iteration
        pToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == pToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        require(assetIndex < len, "accountAssets array broken");

        // copy last item in list to location of item to be removed, reduce length by 1
        pToken[] storage storedList = accountAssets[msg.sender];
        if (assetIndex != storedList.length - 1) {
            storedList[assetIndex] = storedList[storedList.length - 1];
        }
        storedList.length--;

        emit MarketExited(pToken, msg.sender);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param pToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return false and reason if mint not allowed, otherwise return true and empty string
     */
    function mintAllowed(address pToken, address minter, uint mintAmount) external returns (bool allowed, string memory reason) {
        if (mintGuardianPaused[pToken]) {
            allowed = false;
            reason = MINT_PAUSED;
            return (allowed, reason);
        }

        uint supplyCap = supplyCaps[pToken];
        // Supply cap of 0 corresponds to unlimited supplying
        if (supplyCap != 0) {
            uint totalSupply = pToken(pToken).totalSupply();
            uint nextTotalSupply = totalSupply.add(mintAmount);
            if (nextTotalSupply > supplyCap) {
                allowed = false;
                reason = MARKET_SUPPLY_CAP_REACHED;
                return (allowed, reason);
            }
        }

        // Shh - currently unused
        minter;

        if (!markets[pToken].isListed) {
            allowed = false;
            reason = MARKET_NOT_LISTED;
            return (allowed, reason);
        }

        allowed = true;
        return (allowed, reason);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param pToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address pToken, address minter, uint actualMintAmount, uint mintTokens) external {
        // Shh - currently unused
        pToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param pToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of pTokens to exchange for the underlying asset in the market
     * @return false and reason if redeem not allowed, otherwise return true and empty string
     */
    function redeemAllowed(address pToken, address redeemer, uint redeemTokens) external returns (bool allowed, string memory reason) {
        return redeemAllowedInternal(pToken, redeemer, redeemTokens);
    }

    /**
     * @param pToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of pTokens to exchange for the underlying asset in the market
     * @return false and reason if redeem not allowed, otherwise return true and empty string
     */
    function redeemAllowedInternal(address pToken, address redeemer, uint redeemTokens) internal view returns (bool allowed, string memory reason) {
        if (!markets[pToken].isListed) {
            allowed = false;
            reason = MARKET_NOT_LISTED;
            return (allowed, reason);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[pToken].accountMembership[redeemer]) {
            allowed = true;
            return (allowed, reason);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (, uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, pToken(pToken), redeemTokens, 0);
        if (shortfall > 0) {
            allowed = false;
            reason = INSUFFICIENT_LIQUIDITY;
            return (allowed, reason);
        }

        allowed = true;
        return (allowed, reason);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param pToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address pToken, address redeemer, uint redeemTokens) external {
        // Shh - currently unused
        pToken;
        redeemer;

        require(redeemTokens != 0, REDEEM_TOKENS_ZERO);
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param pToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return false and reason if borrow not allowed, otherwise return true and empty string
     */
    function borrowAllowed(address pToken, address borrower, uint borrowAmount) external returns (bool allowed, string memory reason) {
        if (borrowGuardianPaused[pToken]) {
            allowed = false;
            reason = BORROW_PAUSED;
            return (allowed, reason);
        }

        if (!markets[pToken].isListed) {
            allowed = false;
            reason = MARKET_NOT_LISTED;
            return (allowed, reason);
        }

        if (!markets[pToken].accountMembership[borrower]) {
            // only pTokens may call borrowAllowed if borrower not in market
            require(msg.sender == pToken, "sender must be pToken");

            // attempt to add borrower to the market
            addToMarketInternal(pToken(msg.sender), borrower);

            // it should be impossible to break the important invariant
            assert(markets[pToken].accountMembership[borrower]);
        }

        require(oracle.getUnderlyingPrice(pToken) != 0, "price error");

        uint borrowCap = borrowCaps[pToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = pMCD(pToken).totalBorrows();
            uint nextTotalBorrows = totalBorrows.add(borrowAmount);
            if (nextTotalBorrows > borrowCap) {
                allowed = false;
                reason = MARKET_BORROW_CAP_REACHED;
                return (allowed, reason);
            }
        }

        (, uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, pToken(pToken), 0, borrowAmount);
        if (shortfall > 0) {
            allowed = false;
            reason = INSUFFICIENT_LIQUIDITY;
            return (allowed, reason);
        }

        allowed = true;
        return (allowed, reason);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param pToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address pToken, address borrower, uint borrowAmount) external {
        // Shh - currently unused
        pToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param pToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return false and reason if repay borrow not allowed, otherwise return true and empty string
     */
    function repayBorrowAllowed(
        address pToken,
        address payer,
        address borrower,
        uint repayAmount) external returns (bool allowed, string memory reason) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[pToken].isListed) {
            allowed = false;
            reason = MARKET_NOT_LISTED;
        }

        allowed = true;
        return (allowed, reason);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param pToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address pToken,
        address payer,
        address borrower,
        uint actualRepayAmount) external {
        // Shh - currently unused
        pToken;
        payer;
        borrower;
        actualRepayAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     * @return false and reason if liquidate borrow not allowed, otherwise return true and empty string
     */
    function liquidateBorrowAllowed(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external returns (bool allowed, string memory reason) {
        // Shh - currently unused
        liquidator;

        if (!markets[pTokenBorrowed].isListed || !markets[pTokenCollateral].isListed) {
            allowed = false;
            reason = MARKET_NOT_LISTED;
            return (allowed, reason);
        }

        if (pToken(pTokenCollateral).controller() != pToken(pTokenBorrowed).controller()) {
            allowed = false;
            reason = CONTROLLER_MISMATCH;
            return (allowed, reason);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (, uint shortfall) = getAccountLiquidityInternal(borrower);
        if (shortfall == 0) {
            allowed = false;
            reason = INSUFFICIENT_SHORTFALL;
            return (allowed, reason);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        /* Only pMCD has borrow related logics */
        uint borrowBalance = MCD(TokenBorrowed).borrowBalance(borrower);
        uint maxClose = mulScalarTruncate(Exp({mantissa : closeFactorMantissa}), borrowBalance);
        if (repayAmount > maxClose) {
            allowed = false;
            reason = TOO_MUCH_REPAY;
            return (allowed, reason);
        }

        allowed = true;
        return (allowed, reason);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens) external {
        // Shh - currently unused
        pTokenBorrowed;
        pTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     * @return false and reason if seize not allowed, otherwise return true and empty string
     */
    function seizeAllowed(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external returns (bool allowed, string memory reason) {
        if (seizeGuardianPaused) {
            allowed = false;
            reason = SEIZE_PAUSED;
            return (allowed, reason);
        }

        // Shh - currently unused
        seizeTokens;
        liquidator;
        borrower;

        if (!markets[pTokenCollateral].isListed || !markets[pTokenBorrowed].isListed) {
            allowed = false;
            reason = MARKET_NOT_LISTED;
            return (allowed, reason);
        }

        if (pToken(pTokenCollateral).controller() != pToken(pTokenBorrowed).controller()) {
            allowed = false;
            reason = CONTROLLER_MISMATCH;
            return (allowed, reason);
        }

        allowed = true;
        return (allowed, reason);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external {
        // Shh - currently unused
        pTokenCollateral;
        pTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param pToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of pTokens to transfer
     * @return false and reason if seize not allowed, otherwise return true and empty string
     */
    function transferAllowed(address pToken, address src, address dst, uint transferTokens) external returns (bool allowed, string memory reason) {
        if (transferGuardianPaused) {
            allowed = false;
            reason = TRANSFER_PAUSED;
            return (allowed, reason);
        }

        // not used currently
        dst;

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        return redeemAllowedInternal(pToken, src, transferTokens);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param pToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of pTokens to transfer
     */
    function transferVerify(address pToken, address src, address dst, uint transferTokens) external {
        // Shh - currently unused
        pToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `pTokenBalance` is the number of pTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     *  In Plutos Network, user can only borrow pMCD, the `borrowBalance` is the amount of pMCD account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint pTokenBalance;
        uint borrowBalance;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, pToken(0), 0, 0);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account) internal view returns (uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, PToken(0), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param pTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for Plutos pool
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address pTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, pToken(pTokenModify), redeemTokens, borrowAmount);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param pTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for Plutos pool
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        pToken pTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (uint, uint) {

        AccountLiquidityLocalVars memory vars;

        // For each asset the account is in
        pToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            pToken asset = assets[i];

            // Read the balances from the pToken
            (vars.pTokenBalance, vars.borrowBalance) = asset.getAccountSnapshot(account);
            vars.collateralFactor = Exp({mantissa : markets[address(asset)].collateralFactorMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(address(asset));
            require(vars.oraclePriceMantissa != 0, "price error");
            vars.oraclePrice = Exp({mantissa : vars.oraclePriceMantissa});

            // Pre-compute a conversion factor
            vars.tokensToDenom = mulExp(vars.collateralFactor, vars.oraclePrice);

            // sumCollateral += tokensToDenom * pTokenBalance
            vars.sumCollateral = mulScalarTruncateAddUInt(vars.tokensToDenom, vars.kTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mulScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with pTokenModify
            if (asset == pTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mulScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mulScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in pMCD.liquidateBorrowFresh)
     * @param pTokenBorrowed The address of the borrowed pToken
     * @param pTokenCollateral The address of the collateral pToken
     * @param actualRepayAmount The amount of pTokenBorrowed underlying to convert into pTokenCollateral tokens
     * @return number of pTokenCollateral tokens to be seized in a liquidation
     */
    function liquidateCalculateSeizeTokens(address pTokenBorrowed, address pTokenCollateral, uint actualRepayAmount) external view returns (uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(pTokenBorrowed);
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(pTokenCollateral);
        require(priceBorrowedMantissa != 0 && priceCollateralMantissa != 0, "price error");

        /*
         *  calculate the number of collateral tokens to seize:
         *  seizeTokens = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
        */
        Exp memory numerator = mulExp(liquidationIncentiveMantissa, priceBorrowedMantissa);
        Exp memory denominator = Exp({mantissa : priceCollateralMantissa});
        Exp memory ratio = divExp(numerator, denominator);
        uint seizeTokens = mulScalarTruncate(ratio, actualRepayAmount);

        return seizeTokens;
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the controller
      * @dev Admin function to set a new price oracle
      */
    function _setPriceOracle(OracleInterface newOracle) external onlyAdmin() {
        OracleInterface oldOracle = oracle;
        oracle = newOracle;
        emit NewPriceOracle(oldOracle, newOracle);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external onlyAdmin() {
        require(newCloseFactorMantissa <= closeFactorMaxMantissa, INVALID_CLOSE_FACTOR);
        require(newCloseFactorMantissa >= closeFactorMinMantissa, INVALID_CLOSE_FACTOR);

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param pToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      */
    function _setCollateralFactor(pToken pToken, uint newCollateralFactorMantissa) external onlyAdmin() {
        // Verify market is listed
        Market storage market = markets[address(pToken)];
        require(market.isListed, MARKET_NOT_LISTED);

        Exp memory newCollateralFactorExp = Exp({mantissa : newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa : collateralFactorMaxMantissa});
        require(!lessThanExp(highLimit, newCollateralFactorExp), INVALID_COLLATERAL_FACTOR);

        // If collateral factor != 0, fail if price == 0
        require(newCollateralFactorMantissa == 0 || oracle.getUnderlyingPrice(address(kToken)) != 0, "price error");

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(pToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external onlyAdmin() {
        require(newLiquidationIncentiveMantissa <= liquidationIncentiveMaxMantissa, INVALID_LIQUIDATION_INCENTIVE);
        require(newLiquidationIncentiveMantissa >= liquidationIncentiveMinMantissa, INVALID_LIQUIDATION_INCENTIVE);

        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param pToken The address of the market (token) to list
      */
    function _supportMarket(PToken pToken) external onlyAdmin() {
        require(!markets[address(pToken)].isListed, MARKET_ALREADY_LISTED);

        pToken.ispToken();
        // Sanity check to make sure its really a pToken

        markets[address(pToken)] = Market({isListed : true, collateralFactorMantissa : 0});

        _addMarketInternal(address(pToken));

        emit MarketListed(pToken);
    }

    function _addMarketInternal(address pToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != PToken(pToken), MARKET_ALREADY_ADDED);
        }
        allMarkets.push(PToken(pToken));
    }


    /**
      * @notice Set the given borrow caps for the given pToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
      * @dev Admin or capGuardian can call this function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
      * @param pTokens The addresses of the markets (tokens) to change the borrow caps for
      * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
      */
    function _setMarketBorrowCaps(PToken[] calldata pTokens, uint[] calldata newBorrowCaps) external {
        require(msg.sender == admin || msg.sender == capGuardian, "only admin or cap guardian can set borrow caps");

        uint numMarkets = pTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for (uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(pTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(pTokens[i], newBorrowCaps[i]);
        }
    }

    /**
      * @notice Set the given supply caps for the given pToken markets. Supplying that brings total supply to or above supply cap will revert.
      * @dev Admin or capGuardian can call this function to set the supply caps. A supply cap of 0 corresponds to unlimited supplying.
      * @param pTokens The addresses of the markets (tokens) to change the supply caps for
      * @param newSupplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to unlimited supplying.
      */
    function _setMarketSupplyCaps(PToken[] calldata pTokens, uint[] calldata newSupplyCaps) external {
        require(msg.sender == admin || msg.sender == capGuardian, "only admin or cap guardian can set supply caps");

        uint numMarkets = pTokens.length;
        uint numSupplyCaps = newSupplyCaps.length;

        require(numMarkets != 0 && numMarkets == numSupplyCaps, "invalid input");

        for (uint i = 0; i < numMarkets; i++) {
            supplyCaps[address(pTokens[i])] = newSupplyCaps[i];
            emit NewSupplyCap(pTokens[i], newSupplyCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow and Supply Cap Guardian
     * @param newCapGuardian The address of the new Cap Guardian
     */
    function _setCapGuardian(address newCapGuardian) external onlyAdmin() {
        address oldCapGuardian = capGuardian;
        capGuardian = newCapGuardian;
        emit NewCapGuardian(oldCapGuardian, newCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     */
    function _setPauseGuardian(address newPauseGuardian) external onlyAdmin() {
        address oldPauseGuardian = pauseGuardian;
        pauseGuardian = newPauseGuardian;
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);
    }

    function _setMintPaused(PToken pToken, bool state) public returns (bool) {
        require(markets[address(pToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause/unpause");

        mintGuardianPaused[address(pToken)] = state;
        emit ActionPaused(pToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(PToken pToken, bool state) public returns (bool) {
        require(markets[address(pToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause/unpause");

        borrowGuardianPaused[address(pToken)] = state;
        emit ActionPaused(pToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause/unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause/unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        unitroller._acceptImplementation();
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (PToken[] memory) {
        return allMarkets;
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    function getOracle() external view returns (address) {
        return address(oracle);
    }

}
