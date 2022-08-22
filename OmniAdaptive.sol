// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface Omniverse is IERC20, IERC20Metadata {
    function omniAdaptiveTransfer(
        address from,
        address to,
        uint256 amount
    ) external;
}

interface IDEXFactory {
    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);
}

interface IDEXRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function factory() external pure returns (address);
}

contract OmniAdaptive is Ownable, Pausable {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_FEE = 40;
    // Booleans are more expensive than uint256.
    uint256 public constant FALSE = 1;
    uint256 public constant TRUE = 2;

    Omniverse public omniverse;

    struct FreeTransferInfo {
        uint256 freeTransferEnabled;
        // freeTransferCheck maps the address to the index of the address in the freeTransfers array.
        mapping(address => uint256) freeTransferCheck;
        address[] freeTransfers;
    }
    FreeTransferInfo public freeTransferInfo;

    struct TransferFees {
        uint256 buyFee;
        uint256 sellFee;
        uint256 transferFee;
        uint256 feesOnNormalTransfers;
        mapping(address => uint256) isFeeExempt;
        mapping(address => uint256) pairs;
    }
    TransferFees public transferFees;

    mapping(address => uint256) public allowTransfer;

    struct MaxTaxReceiversInfo {
        uint256 sellFee;
        uint256 transferFee;
        uint256 maxTransactionAmount;
        uint256 enabled;
        mapping(address => uint256) maxTaxReceivers;
    }
    MaxTaxReceiversInfo public maxTaxReceiversInfo;

    struct BlacklistingInfo {
        uint256 enabled;
        mapping(address => uint256) blacklist;
    }
    BlacklistingInfo public blacklistingInfo;

    struct SwapbackSettings {
        uint256 inSwap;
        uint256 treasuryPercent;
        uint256 liquidityPercent;
        uint256 burnPercent;
        uint256 swapThreshold;
        uint256 swapEnabled;
        IDEXRouter swapRouter;
        IERC20 swapPairedCoin;
        address treasury;
    }
    SwapbackSettings public swapbackSettings;

    event FreeTransfer(
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event PairUpdated(address indexed addr, bool value);
    event BlacklistUpdated(address indexed addr, bool value);
    event MaxTaxReceiversUpdated(address indexed addr, bool value);
    event FeeExemptUpdated(address indexed addr, bool value);
    event AllowTransferUpdated(address indexed addr, bool value);
    event SwapBack(
        uint256 contractTokenBalance,
        uint256 amountToTreasury,
        uint256 amountToLiquidity,
        uint256 amountToBurn
    );

    modifier swapping() {
        require(swapbackSettings.inSwap != TRUE, "Already inSwap");
        swapbackSettings.inSwap = TRUE;
        _;
        swapbackSettings.inSwap = FALSE;
    }

    constructor(
        address ownerAddr,
        address omniverseAddr,
        address routerAddr,
        address pairedCoinAddr,
        address treasuryAddr
    ) {
        require(ownerAddr != address(0x0), "Owner can't be 0x0");
        require(omniverseAddr != address(0x0), "Omniverse can't be 0x0");
        require(routerAddr != address(0x0), "Router can't be 0x0");
        require(pairedCoinAddr != address(0x0), "Paired coin can't be 0x0");
        require(treasuryAddr != address(0x0), "Treasury can't be 0x0");

        _pause();

        _transferOwnership(ownerAddr);

        omniverse = Omniverse(omniverseAddr);

        // First element in this array should never be used.
        freeTransferInfo.freeTransfers.push(address(0x0));

        transferFees.buyFee = 10;
        transferFees.sellFee = 10;
        transferFees.transferFee = 10;
        transferFees.feesOnNormalTransfers = TRUE;
        transferFees.isFeeExempt[ownerAddr] = TRUE;
        transferFees.isFeeExempt[address(this)] = TRUE;

        allowTransfer[ownerAddr] = TRUE;
        allowTransfer[address(this)] = TRUE;

        // These two lines are to allow creating the LP using the non-multisig address before
        // transfers are enabled. These will be set to false after the fact.
        transferFees.isFeeExempt[msg.sender] = TRUE;
        allowTransfer[msg.sender] = TRUE;

        maxTaxReceiversInfo.sellFee = 30;
        maxTaxReceiversInfo.transferFee = 30;
        maxTaxReceiversInfo.maxTransactionAmount =
            1000 *
            10**omniverse.decimals();
        maxTaxReceiversInfo.enabled = TRUE;

        blacklistingInfo.enabled = TRUE;

        swapbackSettings.inSwap = FALSE;
        swapbackSettings.treasuryPercent = 60;
        swapbackSettings.liquidityPercent = 20;
        swapbackSettings.burnPercent = 20;
        swapbackSettings.swapThreshold = 1000 * 10**omniverse.decimals();
        swapbackSettings.swapEnabled = TRUE;
        swapbackSettings.swapRouter = IDEXRouter(routerAddr);
        swapbackSettings.swapPairedCoin = IERC20(pairedCoinAddr);
        swapbackSettings.treasury = treasuryAddr;

        address swapPair = IDEXFactory(swapbackSettings.swapRouter.factory())
            .createPair(pairedCoinAddr, omniverseAddr);
        transferFees.pairs[swapPair] = TRUE;

        omniverse.approve(routerAddr, type(uint256).max);
        swapbackSettings.swapPairedCoin.approve(routerAddr, type(uint256).max);

        emit PairUpdated(swapPair, true);
        emit FeeExemptUpdated(ownerAddr, true);
        emit FeeExemptUpdated(address(this), true);
        emit FeeExemptUpdated(msg.sender, true);
        emit AllowTransferUpdated(ownerAddr, true);
        emit AllowTransferUpdated(address(this), true);
        emit AllowTransferUpdated(msg.sender, true);
    }

    receive() external payable {}

    function transferOmni(
        address from,
        address to,
        uint256 amount
    ) external {
        require(
            msg.sender == address(omniverse),
            "Can only be called by Omniverse"
        );
        (bool canTransfer, uint256 amountToTax) = transferData(
            from,
            to,
            amount
        );
        require(canTransfer, "Transfer not allowed");
        if (amountToTax > 0)
            omniverse.omniAdaptiveTransfer(from, address(this), amountToTax);
        omniverse.omniAdaptiveTransfer(from, to, amount - amountToTax);
    }

    function freeTransferOmni(address to, uint256 amount) external {
        require(
            checkFreeTransfer(msg.sender, to, amount),
            "Cannot use this function"
        );
        freeTransferInfo.freeTransferCheck[msg.sender] = freeTransferInfo
            .freeTransfers
            .length;
        freeTransferInfo.freeTransfers.push(msg.sender);
        omniverse.omniAdaptiveTransfer(msg.sender, to, amount);
        emit FreeTransfer(msg.sender, to, amount);
    }

    function enableTransfers() external onlyOwner {
        _unpause();
    }

    function disableTransfers() external onlyOwner {
        _pause();
    }

    function setFreeTransferEnabled(bool enabled) external onlyOwner {
        freeTransferInfo.freeTransferEnabled = boolToUint(enabled);
    }

    function resetFreeTransferForAddress(address addr) external onlyOwner {
        uint idx = freeTransferInfo.freeTransferCheck[addr];
        require(idx != 0, "Address already reset");
        address lastElement = freeTransferInfo.freeTransfers[
            freeTransferInfo.freeTransfers.length - 1
        ];
        freeTransferInfo.freeTransfers[idx] = lastElement;
        freeTransferInfo.freeTransfers.pop();
        freeTransferInfo.freeTransferCheck[lastElement] = idx;
        delete freeTransferInfo.freeTransferCheck[addr];
    }

    /**
     * This function only resets up to 100 addresses. If there are more
     * addresses that need to be reset, this function will need to be
     * called multiple times until no more addresses can be reset. If there
     * are no more addresses that can be reset, this function will revert.
     * Check the freeTransferInfo.freeTransfers array to find out how many
     * addresses need to be reset. If it has only one element with the 0x0
     * address, then that means that all free transfers have been reset.
     *
     * This function also sets freeTransferInfo.freeTransferEnabled to
     * false so that no one can abuse the free transfers while this function
     * is being called. setFreeTransferEnabled(true) has to be manually
     * called after all free transfers have been reset.
     */
    function resetFreeTransfers() external onlyOwner {
        require(
            freeTransferInfo.freeTransfers.length > 1,
            "All free transfers are already reset"
        );
        freeTransferInfo.freeTransferEnabled = FALSE;
        uint min = freeTransferInfo.freeTransfers.length - 1;
        if (min > 100) min = 100;
        for (uint i = 0; i < min; i++) {
            delete freeTransferInfo.freeTransferCheck[
                freeTransferInfo.freeTransfers[
                    freeTransferInfo.freeTransfers.length - 1
                ]
            ];
            freeTransferInfo.freeTransfers.pop();
        }
    }

    function setTradingPair(address pair, bool enabled) external onlyOwner {
        uint256 b = boolToUint(enabled);
        if (transferFees.pairs[pair] != b) {
            transferFees.pairs[pair] = b;
            emit PairUpdated(pair, enabled);
        }
    }

    function setFeesInfo(
        uint256 buyPercent,
        uint256 sellPercent,
        uint256 transferPercent,
        bool feesOnNormalTransfersEnabled
    ) external onlyOwner {
        require(buyPercent <= MAX_FEE, "Exceeded max fee");
        require(sellPercent <= MAX_FEE, "Exceeded max fee");
        require(transferPercent <= MAX_FEE, "Exceeded max fee");

        transferFees.buyFee = buyPercent;
        transferFees.sellFee = sellPercent;
        transferFees.transferFee = transferPercent;
        transferFees.feesOnNormalTransfers = boolToUint(
            feesOnNormalTransfersEnabled
        );
    }

    function setMaxTaxReceiversInfo(
        uint256 sellFee,
        uint256 transferFee,
        uint256 maxTxnAmount,
        bool maxTaxReceiversEnabled
    ) external onlyOwner {
        require(sellFee <= MAX_FEE, "Exceeded max fee");
        require(transferFee <= MAX_FEE, "Exceeded max fee");
        maxTaxReceiversInfo.sellFee = sellFee;
        maxTaxReceiversInfo.transferFee = transferFee;
        maxTaxReceiversInfo.maxTransactionAmount = maxTxnAmount;
        maxTaxReceiversInfo.enabled = boolToUint(maxTaxReceiversEnabled);
    }

    function setBlacklistingEnabled(bool enabled) external onlyOwner {
        blacklistingInfo.enabled = boolToUint(enabled);
    }

    function setBlacklist(address addr, bool flag) external onlyOwner {
        blacklistingInfo.blacklist[addr] = boolToUint(flag);
        emit BlacklistUpdated(addr, flag);
    }

    function setMaxTaxReceivers(address addr, bool flag) external onlyOwner {
        maxTaxReceiversInfo.maxTaxReceivers[addr] = boolToUint(flag);
        emit MaxTaxReceiversUpdated(addr, flag);
    }

    function setFeeExempt(address addr, bool enabled) external onlyOwner {
        transferFees.isFeeExempt[addr] = boolToUint(enabled);
        emit FeeExemptUpdated(addr, enabled);
    }

    function setAllowTransfer(address addr, bool allowed) external onlyOwner {
        allowTransfer[addr] = boolToUint(allowed);
        emit AllowTransferUpdated(addr, allowed);
    }

    function setSwapBackSettings(
        uint256 treasuryPercent,
        uint256 liquidityPercent,
        uint256 burnPercent,
        uint256 swapThreshold,
        bool swapEnabled,
        address routerAddr,
        address pairedCoinAddr,
        address treasuryAddr
    ) external onlyOwner {
        require(swapbackSettings.inSwap != TRUE, "Can't run while inSwap");
        require(
            treasuryPercent + liquidityPercent + burnPercent == 100,
            "Sum of percentages doesn't add to 100"
        );
        swapbackSettings.treasuryPercent = treasuryPercent;
        swapbackSettings.liquidityPercent = liquidityPercent;
        swapbackSettings.burnPercent = burnPercent;
        swapbackSettings.swapThreshold = swapThreshold;
        swapbackSettings.swapEnabled = boolToUint(swapEnabled);
        if (routerAddr != address(0x0))
            swapbackSettings.swapRouter = IDEXRouter(routerAddr);
        if (pairedCoinAddr != address(0x0))
            swapbackSettings.swapPairedCoin = IERC20(pairedCoinAddr);
        if (treasuryAddr != address(0x0))
            swapbackSettings.treasury = treasuryAddr;

        if (routerAddr != address(0x0) || pairedCoinAddr != address(0x0)) {
            address swapPair = IDEXFactory(
                swapbackSettings.swapRouter.factory()
            ).createPair(
                    address(swapbackSettings.swapPairedCoin),
                    address(omniverse)
                );
            if (transferFees.pairs[swapPair] != TRUE) {
                transferFees.pairs[swapPair] = TRUE;
                emit PairUpdated(swapPair, true);
            }

            swapbackSettings.swapPairedCoin.approve(
                address(swapbackSettings.swapRouter),
                type(uint256).max
            );
        }

        if (routerAddr != address(0x0)) {
            omniverse.approve(routerAddr, type(uint256).max);
        }
    }

    /**
     * This function is meant to be called by the Gelato bot, but really
     * it can be called by anyone. It will enforce that shouldSwapback
     * is true anyways.
     */
    function swapBack() external swapping {
        require(swapbackSettings.swapEnabled == TRUE, "swapBack is disabled");

        uint256 contractBalance = omniverse.balanceOf(address(this));
        require(
            contractBalance >= swapbackSettings.swapThreshold,
            "Below swapBack threshold"
        );

        swapBackPrivate(contractBalance);
    }

    function rescueETH() external onlyOwner {
        (bool sent, ) = msg.sender.call{value: address(this).balance}("");
        require(sent, "Failed to send Ether");
    }

    function rescueERC20Token(address tokenAddr) external onlyOwner {
        IERC20 token = IERC20(tokenAddr);
        require(
            token.transfer(msg.sender, token.balanceOf(address(this))),
            "Transfer failed"
        );
    }

    function checkFreeTransfer(
        address from,
        address to,
        uint256 amount
    ) public view returns (bool) {
        return (omniverse.balanceOf(from) >= amount &&
            amount > 0 &&
            allowedToTransfer(from, to, amount) &&
            freeTransferInfo.freeTransferEnabled == TRUE &&
            freeTransferInfo.freeTransferCheck[from] == 0);
    }

    /// This is to be used as the resolver function in Gelato for swapBack
    function shouldSwapback()
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        canExec =
            swapbackSettings.inSwap != TRUE &&
            swapbackSettings.swapEnabled == TRUE &&
            omniverse.balanceOf(address(this)) >=
            swapbackSettings.swapThreshold;
        execPayload = abi.encodeWithSelector(this.swapBack.selector);
    }

    function getTaxPercentages(address addr)
        public
        view
        returns (
            uint256 buyPercentage,
            uint256 sellPercentage,
            uint256 transferPercentage
        )
    {
        buyPercentage = transferFees.buyFee;
        sellPercentage = getSellFee(addr);
        transferPercentage = getTransferFee(addr);
    }

    function transferData(
        address from,
        address to,
        uint256 amount
    ) public view returns (bool canTransfer, uint256 amountToTax) {
        canTransfer = allowedToTransfer(from, to, amount);

        amountToTax = 0;
        if (shouldTakeFee(from, to)) {
            uint256 totalFee;
            (
                uint256 buyFee,
                uint256 sellFee,
                uint256 transferFee
            ) = getTaxPercentages(from);
            if (transferFees.pairs[from] == TRUE) {
                totalFee = buyFee;
            } else if (transferFees.pairs[to] == TRUE) {
                totalFee = sellFee;
            } else {
                totalFee = transferFee;
            }

            amountToTax = (amount * totalFee) / 100;
        }
    }

    function shouldTakeFee(address from, address to)
        public
        view
        returns (bool)
    {
        if (maxTaxReceiverRestrictionsApply(from, to)) {
            return true;
        } else if (
            transferFees.isFeeExempt[from] == TRUE ||
            transferFees.isFeeExempt[to] == TRUE
        ) {
            return false;
        }
        return (transferFees.feesOnNormalTransfers == TRUE ||
            transferFees.pairs[from] == TRUE ||
            transferFees.pairs[to] == TRUE);
    }

    function getBlacklist(address addr) public view returns (bool) {
        return
            blacklistingInfo.blacklist[addr] == TRUE &&
            blacklistingInfo.enabled == TRUE;
    }

    function maxTaxReceiverRestrictionsApply(address from, address to)
        public
        view
        returns (bool)
    {
        return getMaxTaxReceiver(from) && transferFees.isFeeExempt[to] != TRUE;
    }

    function getMaxTaxReceiver(address addr) public view returns (bool) {
        return
            maxTaxReceiversInfo.maxTaxReceivers[addr] == TRUE &&
            maxTaxReceiversInfo.enabled == TRUE;
    }

    function swapBackPrivate(uint256 contractBalance) private {
        uint256 feeAmountToLiquidity = (contractBalance *
            swapbackSettings.liquidityPercent) / 100;
        uint256 feeAmountToTreasury = (contractBalance *
            swapbackSettings.treasuryPercent) / 100;

        // Only transfer to the paired coin half of the liquidity tokens, and all of the treasury tokens.
        uint256 amountToPairedCoin = feeAmountToLiquidity /
            2 +
            feeAmountToTreasury;

        // Swap once to the paired coin.
        uint256 balancePairedCoin = swapbackSettings.swapPairedCoin.balanceOf(
            address(this)
        );
        if (amountToPairedCoin > 0) {
            swapTokensForPairedCoin(amountToPairedCoin);
        }
        balancePairedCoin =
            swapbackSettings.swapPairedCoin.balanceOf(address(this)) -
            balancePairedCoin;

        // The percentage of the OMNI balance that has been swapped to the paired coin.
        // Multiplied by 10 for more accuracy.
        uint256 percentToPairedCoin = (swapbackSettings.liquidityPercent * 10) /
            2 +
            swapbackSettings.treasuryPercent *
            10;

        // The amounts of the paired coin that will go to the liquidity and treasury.
        uint256 amountLiquidityPairedCoin = (balancePairedCoin *
            swapbackSettings.liquidityPercent *
            10) /
            2 /
            percentToPairedCoin;

        if (amountLiquidityPairedCoin > 0) {
            // Add to liquidity the second half of the liquidity tokens,
            // and the corresponding percentage of the paired coin.
            addLiquidity(
                feeAmountToLiquidity - feeAmountToLiquidity / 2,
                amountLiquidityPairedCoin
            );
        }

        if (swapbackSettings.swapPairedCoin.balanceOf(address(this)) > 0) {
            require(
                swapbackSettings.swapPairedCoin.transfer(
                    swapbackSettings.treasury,
                    swapbackSettings.swapPairedCoin.balanceOf(address(this))
                ),
                "Failed to transfer paired coin to treasury address"
            );
        }

        uint256 feeAmountToBurn = omniverse.balanceOf(address(this));

        if (feeAmountToBurn > 0) {
            require(
                omniverse.transfer(DEAD, feeAmountToBurn),
                "Failed to burn OMNI tokens"
            );
        }

        emit SwapBack(
            contractBalance,
            feeAmountToTreasury,
            feeAmountToLiquidity,
            feeAmountToBurn
        );
    }

    function swapTokensForPairedCoin(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(omniverse);
        path[1] = address(swapbackSettings.swapPairedCoin);

        swapbackSettings
            .swapRouter
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                tokenAmount,
                0,
                path,
                address(this),
                block.timestamp
            );
    }

    function addLiquidity(uint256 tokenAmount, uint256 pairedCoinAmount)
        private
    {
        (uint256 amountA, uint256 amountB, ) = swapbackSettings
            .swapRouter
            .addLiquidity(
                address(omniverse),
                address(swapbackSettings.swapPairedCoin),
                tokenAmount,
                pairedCoinAmount,
                0,
                0,
                swapbackSettings.treasury,
                block.timestamp
            );
        require(
            amountA == tokenAmount || amountB == pairedCoinAmount,
            "Incorrect liquidity amount was added"
        );
    }

    function allowedToTransfer(
        address from,
        address to,
        uint256 amount
    ) private view returns (bool) {
        return ((!paused() ||
            allowTransfer[from] == TRUE ||
            allowTransfer[to] == TRUE) &&
            (!getBlacklist(from) && !getBlacklist(to)) &&
            (amount <= maxTaxReceiversInfo.maxTransactionAmount ||
                !maxTaxReceiverRestrictionsApply(from, to)));
    }

    function getSellFee(address addr)
        private
        view
        returns (uint256 sellPercentage)
    {
        sellPercentage = transferFees.sellFee;
        if (getMaxTaxReceiver(addr)) {
            sellPercentage = maxTaxReceiversInfo.sellFee;
        }
    }

    function getTransferFee(address addr)
        private
        view
        returns (uint256 transferPercentage)
    {
        transferPercentage = transferFees.transferFee;
        if (getMaxTaxReceiver(addr)) {
            transferPercentage = maxTaxReceiversInfo.transferFee;
        }
    }

    function boolToUint(bool b) private pure returns (uint256) {
        if (b) {
            return TRUE;
        }
        return FALSE;
    }
}