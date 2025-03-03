// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IMasonry.sol";
import "./interfaces/ITShareRewardPool.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TombVanillaCompounder is Ownable {
	using SafeERC20 for IERC20;

	// Tokens
	IERC20 tomb;
	IERC20 tshare;
	IUniswapV2Pair spookyTombFtmLP;

	// Tomb's smart contracts
	IMasonry masonry;
	ITShareRewardPool cemetery;

	// SpookySwap's smart contracts
	IUniswapV2Router02 spookyRouter;

	// Slippage for interactions with SpookySwap
	// 1 means 0.1%, 10 means 1%, and so on...
	uint256 slippageInTenthOfPercent = 10;

	constructor(
		address _tomb,
		address _tshare,
		address _spookyTombFtmLP,
		address _masonry,
		address _cemetery,
		address _spookyRouter
	) {
		tomb = IERC20(_tomb);
		tshare = IERC20(_tshare);
		spookyTombFtmLP = IUniswapV2Pair(_spookyTombFtmLP);
		masonry = IMasonry(_masonry);
		cemetery = ITShareRewardPool(_cemetery);
		spookyRouter = IUniswapV2Router02(_spookyRouter);
	}

	// Fallback payable function
	receive() external payable {}

	// Getters for balances at Tomb against this contract's address
	function getTSHAREBalanceAtTombMasonry() public view returns (uint256) {
		return masonry.balanceOf(address(this));
	}

	function getLPBalanceAtTombCemetery() public view returns (uint256) {
		(uint256 amount, ) = cemetery.userInfo(0, address(this));
		return amount;
	}

	// Functions to withdraw tokens only from this contract
	function withdrawDustFTM() external onlyOwner {
		require(address(this).balance > 0, "No dust FTM to withdraw!");
		payable(msg.sender).transfer(address(this).balance);
	}

	function withdrawDustTOMB() external onlyOwner {
		require(tomb.balanceOf(address(this)) > 0, "No dust TOMB to withdraw!");
		tomb.safeTransfer(msg.sender, tomb.balanceOf(address(this)));
	}

	// Functions to withdraw tokens both from this contract and from Tomb
	function withdrawTSHARE() external onlyOwner returns (string memory) {
		string memory masonryStatus;
		if (getTSHAREBalanceAtTombMasonry() > 0) {
			if (masonry.canWithdraw(address(this))) {
				masonry.withdraw(masonry.balanceOf(address(this)));	
			} else {
				masonryStatus = "Masonry has balance but cannot withdraw just yet. Try again later.";	
			}
			
		} else {
			masonryStatus = "No TSHAREs left in Masonry.";
		}
		tshare.safeTransfer(msg.sender, tshare.balanceOf(address(this)));
		return masonryStatus;
	}

	function withdrawLP() external onlyOwner {
		cemetery.withdraw(0, getLPBalanceAtTombCemetery());
		spookyTombFtmLP.transfer(msg.sender, spookyTombFtmLP.balanceOf(address(this)));
	}

	// Deposit LPs into this contract, which then get deposited into Tomb's Cemetery
	// The caller must have approved this contract to spend the LPs beforehand
	function depositLP(uint256 _amount) external {
		require(spookyTombFtmLP.allowance(msg.sender, address(this)) >= _amount, "Don't have allowance for this amount!");
		spookyTombFtmLP.transferFrom(msg.sender, address(this), _amount);
		spookyTombFtmLP.approve(address(cemetery), _amount);
		cemetery.deposit(0, _amount);
	}

	function setSlippage(uint256 _slippageInTenthOfPercent) external onlyOwner {
		slippageInTenthOfPercent = _slippageInTenthOfPercent;
	}

	// Run the vanilla Tomb routine
	function runRoutine() external {
		_claimAnyTSHARERewardsFromCemetery();
		_claimAnyTOMBRewardsFromMasonryIfAllowed();

		_depositAnyTSHAREIntoMasonry();

		_swapHalfTOMBForFTM();
		_addFTMTOMBLiquidity();
		_depositAnyLPIntoCemetery();
	}

	function _claimAnyTSHARERewardsFromCemetery() internal {
		// calling withdraw with amount as 0 simply claims any pending TSHAREs
		cemetery.withdraw(0, 0);
	}

	function _claimAnyTOMBRewardsFromMasonryIfAllowed() internal {
		if (masonry.earned(address(this)) > 0 && masonry.canClaimReward(address(this))) {
			masonry.claimReward();
		}
	}

	function _depositAnyTSHAREIntoMasonry() internal {
		uint256 contractTSHAREBalance = tshare.balanceOf(address(this));
		if (contractTSHAREBalance > 0) {
			tshare.safeIncreaseAllowance(address(masonry), contractTSHAREBalance);
			masonry.stake(contractTSHAREBalance);
		}
	}

	function _swapHalfTOMBForFTM() internal {
		uint256 contractTOMBBalance = tomb.balanceOf(address(this));
		if (contractTOMBBalance > 0) {
			uint256 halfTOMB = contractTOMBBalance / 2;
			tomb.approve(address(spookyRouter), halfTOMB);

			address[] memory path = new address[](2);
			path[0] = address(tomb);
			path[1] = spookyRouter.WETH();

			uint[] memory amountOutMins = spookyRouter.getAmountsOut(halfTOMB, path);
			uint256 minFTMExpected = amountOutMins[1] - ((slippageInTenthOfPercent * amountOutMins[1]) / 1000);

			spookyRouter.swapExactTokensForETH(halfTOMB, minFTMExpected, path, address(this), block.timestamp);
		}
	}

	function _addFTMTOMBLiquidity() internal {
		uint256 contractTOMBBalance = tomb.balanceOf(address(this));
		uint256 contractFTMBalance = address(this).balance;

		if (contractTOMBBalance > 0 && contractFTMBalance > 0) {
			tomb.approve(address(spookyRouter), contractTOMBBalance);

			uint256 minTOMB = contractTOMBBalance - ((slippageInTenthOfPercent * contractTOMBBalance) / 1000);
			uint256 minFTM = contractFTMBalance - ((slippageInTenthOfPercent * contractFTMBalance) / 1000);

			spookyRouter.addLiquidityETH{value: contractFTMBalance}(
				address(tomb), contractTOMBBalance, minTOMB, minFTM, address(this), block.timestamp);
		}
	}

	function _depositAnyLPIntoCemetery() internal {
		uint256 contractLPBalance = spookyTombFtmLP.balanceOf(address(this));
		if (contractLPBalance > 0) {
			spookyTombFtmLP.approve(address(cemetery), contractLPBalance);
			cemetery.deposit(0, contractLPBalance);
		}
	}
}
