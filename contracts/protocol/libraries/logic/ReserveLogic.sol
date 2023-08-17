// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.10;

import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {GPv2SafeERC20} from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {IStableDebtToken} from '../../../interfaces/IStableDebtToken.sol';
import {IVariableDebtToken} from '../../../interfaces/IVariableDebtToken.sol';
import {IReserveInterestRateStrategy} from '../../../interfaces/IReserveInterestRateStrategy.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {MathUtils} from '../math/MathUtils.sol';
import {WadRayMath} from '../math/WadRayMath.sol';
import {PercentageMath} from '../math/PercentageMath.sol';
import {Errors} from '../helpers/Errors.sol';
import {DataTypes} from '../types/DataTypes.sol';
import {SafeCast} from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';

/**
 * @title ReserveLogic library
 * @author Aave
 * @notice Implements the logic to update the reserves state
 */
library ReserveLogic {
  using WadRayMath for uint256;
  using PercentageMath for uint256;
  using SafeCast for uint256;
  using GPv2SafeERC20 for IERC20;
  using ReserveLogic for DataTypes.ReserveData;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  // See `IPool` for descriptions
  event ReserveDataUpdated(
    address indexed reserve,
    uint256 liquidityRate,
    uint256 stableBorrowRate,
    uint256 variableBorrowRate,
    uint256 liquidityIndex,
    uint256 variableBorrowIndex
  );

  /** 返回储备金正在进行的规范化收入（单利计算）
   * @notice Returns the ongoing normalized income for the reserve.
   * @dev A value of 1e27 means there is no income. As time passes, the income is accrued
   * @dev A value of 2*1e27 means for each unit of asset one unit of income has been accrued
   * @param reserve The reserve object
   * @return The normalized income, expressed in ray
   */
  function getNormalizedIncome(
    DataTypes.ReserveData storage reserve
  ) internal view returns (uint256) {
    uint40 timestamp = reserve.lastUpdateTimestamp;

    //solium-disable-next-line
    if (timestamp == block.timestamp) {
      //if the index was updated in the same block, no need to perform any calculation
      return reserve.liquidityIndex;
    } else {
      return
        MathUtils.calculateLinearInterest(reserve.currentLiquidityRate, timestamp).rayMul(
          reserve.liquidityIndex
        );
    }
  }

  /**
   * @notice Returns the ongoing normalized variable debt for the reserve.
   * @dev A value of 1e27 means there is no debt. As time passes, the debt is accrued
   * @dev A value of 2*1e27 means that for each unit of debt, one unit worth of interest has been accumulated
   * @param reserve The reserve object
   * @return The normalized variable debt, expressed in ray
   */
  function getNormalizedDebt(
    DataTypes.ReserveData storage reserve
  ) internal view returns (uint256) {
    uint40 timestamp = reserve.lastUpdateTimestamp;

    //solium-disable-next-line
    if (timestamp == block.timestamp) {
      //if the index was updated in the same block, no need to perform any calculation
      return reserve.variableBorrowIndex;
    } else {
      return
        MathUtils.calculateCompoundedInterest(reserve.currentVariableBorrowRate, timestamp).rayMul(
          reserve.variableBorrowIndex
        );
    }
  }

  /** 更新流动性累积指数和可变借款指数
   * @notice Updates the liquidity cumulative index and the variable borrow index.
   * @param reserve The reserve object
   * @param reserveCache The caching layer for the reserve data
   */
  function updateState(
    DataTypes.ReserveData storage reserve,
    DataTypes.ReserveCache memory reserveCache
  ) internal {
    // If time didn't pass since last stored timestamp, skip state update
    // solium-disable-next-line
    if (reserve.lastUpdateTimestamp == uint40(block.timestamp)) {
      return;
    }
    // 更新Index系列变量（贴现变量）
    _updateIndexes(reserve, reserveCache);
    // 更新风险准备金
    _accrueToTreasury(reserve, reserveCache);

    // solium-disable-next-line
    reserve.lastUpdateTimestamp = uint40(block.timestamp);
  }

  /** 将预定数量的资产积累到准备金中，作为固定的即时收入
   * @notice Accumulates a predefined amount of asset to the reserve as a fixed, instantaneous income. Used for example
   * to accumulate the flashloan fee to the reserve, and spread it between all the suppliers.
   * @param reserve The reserve object
   * @param totalLiquidity The total liquidity available in the reserve
   * @param amount The amount to accumulate
   * @return The next liquidity index of the reserve
   */
  function cumulateToLiquidityIndex(
    DataTypes.ReserveData storage reserve,
    uint256 totalLiquidity,
    uint256 amount
  ) internal returns (uint256) {
    //next liquidity index is calculated this way: `((amount / totalLiquidity) + 1) * liquidityIndex`
    //division `amount / totalLiquidity` done in ray for precision
    uint256 result = (amount.wadToRay().rayDiv(totalLiquidity.wadToRay()) + WadRayMath.RAY).rayMul(
      reserve.liquidityIndex
    );
    reserve.liquidityIndex = result.toUint128();
    return result;
  }

  /**
   * @notice Initializes a reserve.
   * @param reserve The reserve object
   * @param aTokenAddress The address of the overlying atoken contract
   * @param stableDebtTokenAddress The address of the overlying stable debt token contract
   * @param variableDebtTokenAddress The address of the overlying variable debt token contract
   * @param interestRateStrategyAddress The address of the interest rate strategy contract
   */
  function init(
    DataTypes.ReserveData storage reserve,
    address aTokenAddress,
    address stableDebtTokenAddress,
    address variableDebtTokenAddress,
    address interestRateStrategyAddress
  ) internal {
    require(reserve.aTokenAddress == address(0), Errors.RESERVE_ALREADY_INITIALIZED);

    reserve.liquidityIndex = uint128(WadRayMath.RAY);
    reserve.variableBorrowIndex = uint128(WadRayMath.RAY);
    reserve.aTokenAddress = aTokenAddress;
    reserve.stableDebtTokenAddress = stableDebtTokenAddress;
    reserve.variableDebtTokenAddress = variableDebtTokenAddress;
    reserve.interestRateStrategyAddress = interestRateStrategyAddress;
  }

  struct UpdateInterestRatesLocalVars {
    uint256 nextLiquidityRate;
    uint256 nextStableRate;
    uint256 nextVariableRate;
    uint256 totalVariableDebt;
  }

  /**
   * @notice Updates the reserve current stable borrow rate, the current variable borrow rate and the current liquidity rate.
   * @param reserve The reserve reserve to be updated
   * @param reserveCache The caching layer for the reserve data
   * @param reserveAddress The address of the reserve to be updated
   * @param liquidityAdded The amount of liquidity added to the protocol (supply or repay) in the previous action
   * @param liquidityTaken The amount of liquidity taken from the protocol (redeem or borrow)
   */
  function updateInterestRates(
    DataTypes.ReserveData storage reserve,
    DataTypes.ReserveCache memory reserveCache,
    address reserveAddress,
    uint256 liquidityAdded, // 流动性增加量，在此处为存入资产的数量
    uint256 liquidityTaken // 流动性移除量，此变量用于贷出资产的情况，supply的时候是 0
  ) internal {
    UpdateInterestRatesLocalVars memory vars;

    vars.totalVariableDebt = reserveCache.nextScaledVariableDebt.rayMul(
      reserveCache.nextVariableBorrowIndex
    );

    (
      vars.nextLiquidityRate,
      vars.nextStableRate,
      vars.nextVariableRate
    ) = IReserveInterestRateStrategy(reserve.interestRateStrategyAddress).calculateInterestRates(
      DataTypes.CalculateInterestRatesParams({
        unbacked: reserve.unbacked, // 无存入直接铸造的代币数量上限(此变量用于跨链)
        liquidityAdded: liquidityAdded, // 流动性增加量，在此处为存入资产的数量
        liquidityTaken: liquidityTaken, //  流动性移除量，此变量用于贷出资产的情况，supply的时候是 0
        totalStableDebt: reserveCache.nextTotalStableDebt, // 固定利率总贷出量
        totalVariableDebt: vars.totalVariableDebt, // 浮动利率总贷出量
        averageStableBorrowRate: reserveCache.nextAvgStableBorrowRate, // 平均贷款固定利率
        reserveFactor: reserveCache.reserveFactor, // 准备金比率
        reserve: reserveAddress, // 存款Token地址
        aToken: reserveCache.aTokenAddress // 对应的aToken 地址
      })
    );
    // 当前存款利率
    reserve.currentLiquidityRate = vars.nextLiquidityRate.toUint128();
    // 当前固定贷款利率
    reserve.currentStableBorrowRate = vars.nextStableRate.toUint128();
    // 当前浮动贷款利率
    reserve.currentVariableBorrowRate = vars.nextVariableRate.toUint128();

    emit ReserveDataUpdated(
      reserveAddress,
      vars.nextLiquidityRate,
      vars.nextStableRate,
      vars.nextVariableRate,
      reserveCache.nextLiquidityIndex,
      reserveCache.nextVariableBorrowIndex
    );
  }

  struct AccrueToTreasuryLocalVars {
    uint256 prevTotalStableDebt;
    uint256 prevTotalVariableDebt;
    uint256 currTotalVariableDebt;
    uint256 cumulatedStableInterest;
    uint256 totalDebtAccrued;
    uint256 amountToMint;
  }

  /**
   * @notice Mints part of the repaid interest to the reserve treasury as a function of the reserve factor for the
   * specific asset.
   * @param reserve The reserve to be updated
   * @param reserveCache The caching layer for the reserve data
   */
  function _accrueToTreasury(
    DataTypes.ReserveData storage reserve,
    DataTypes.ReserveCache memory reserveCache
  ) internal {
    AccrueToTreasuryLocalVars memory vars;

    if (reserveCache.reserveFactor == 0) {
      return;
    }

    //calculate the total variable debt at moment of the last interaction
    vars.prevTotalVariableDebt = reserveCache.currScaledVariableDebt.rayMul(
      reserveCache.currVariableBorrowIndex
    );

    //calculate the new total variable debt after accumulation of the interest on the index
    vars.currTotalVariableDebt = reserveCache.currScaledVariableDebt.rayMul(
      reserveCache.nextVariableBorrowIndex
    );

    //calculate the stable debt until the last timestamp update
    vars.cumulatedStableInterest = MathUtils.calculateCompoundedInterest(
      reserveCache.currAvgStableBorrowRate,
      reserveCache.stableDebtLastUpdateTimestamp,
      reserveCache.reserveLastUpdateTimestamp
    );

    vars.prevTotalStableDebt = reserveCache.currPrincipalStableDebt.rayMul(
      vars.cumulatedStableInterest
    );

    //debt accrued is the sum of the current debt minus the sum of the debt at the last update
    // 应计债务是当前债务减去上次更新时债务的总和
    vars.totalDebtAccrued =
      vars.currTotalVariableDebt +
      reserveCache.currTotalStableDebt -
      vars.prevTotalVariableDebt -
      vars.prevTotalStableDebt;

    vars.amountToMint = vars.totalDebtAccrued.percentMul(reserveCache.reserveFactor);

    if (vars.amountToMint != 0) {
      reserve.accruedToTreasury += vars
        .amountToMint
        .rayDiv(reserveCache.nextLiquidityIndex)
        .toUint128();
    }
  }

  /**
   * @notice Updates the reserve indexes and the timestamp of the update.
   * @param reserve The reserve reserve to be updated
   * @param reserveCache The cache layer holding the cached protocol data
   */

  function _updateIndexes(
    DataTypes.ReserveData storage reserve,
    DataTypes.ReserveCache memory reserveCache
  ) internal {
    // Only cumulating on the supply side if there is any income being produced
    // The case of Reserve Factor 100% is not a problem (currentLiquidityRate == 0),
    // as liquidity index should not be updated
    // currLiquidityRate == 0 说明池子还没有流动性
    if (reserveCache.currLiquidityRate != 0) {
      // LRt * Δyear + 1
      uint256 cumulatedLiquidityInterest = MathUtils.calculateLinearInterest(
        reserveCache.currLiquidityRate,
        reserveCache.reserveLastUpdateTimestamp
      );
      // 用于计算新的存款贴现因子（净值 一个Atoken的价格）
      // ( LRt * Δyear + 1)LIt-1
      reserveCache.nextLiquidityIndex = cumulatedLiquidityInterest.rayMul(
        reserveCache.currLiquidityIndex
      );
      // 用于保证uint256向uint128转换的安全无溢出
      reserve.liquidityIndex = reserveCache.nextLiquidityIndex.toUint128();
    }

    // Variable borrow index only gets updated if there is any variable debt.
    // reserveCache.currVariableBorrowRate != 0 is not a correct validation,
    // because a positive base variable rate can be stored on
    // reserveCache.currVariableBorrowRate, but the index should not increase
    // 浮动借款指数只有在存在浮动债务时才会更新。
    if (reserveCache.currScaledVariableDebt != 0) {
      // 计算复利
      uint256 cumulatedVariableBorrowInterest = MathUtils.calculateCompoundedInterest(
        reserveCache.currVariableBorrowRate,
        reserveCache.reserveLastUpdateTimestamp
      );
      // 计算浮动借款利率（用于计算浮动借款贴现因子）
      reserveCache.nextVariableBorrowIndex = cumulatedVariableBorrowInterest.rayMul(
        reserveCache.currVariableBorrowIndex
      );
      // 计算浮动借款指数
      reserve.variableBorrowIndex = reserveCache.nextVariableBorrowIndex.toUint128();
    }
  }

  /**
   * @notice Creates a cache object to avoid repeated storage reads and external contract calls when updating state and interest rates.(创建缓存对象，以避免在更新状态和时重复读取storage和调用外部合约利率)
   * @param reserve The reserve object for which the cache will be filled
   * @return The cache object
   */
  function cache(
    DataTypes.ReserveData storage reserve
  ) internal view returns (DataTypes.ReserveCache memory) {
    DataTypes.ReserveCache memory reserveCache;

    reserveCache.reserveConfiguration = reserve.configuration;
    // 获取储备系数
    reserveCache.reserveFactor = reserveCache.reserveConfiguration.getReserveFactor();
    // 存款累计利率（贴现因子）
    reserveCache.currLiquidityIndex = reserveCache.nextLiquidityIndex = reserve.liquidityIndex;
    // 浮动借款累计利率（贴现因子）
    reserveCache.currVariableBorrowIndex = reserveCache.nextVariableBorrowIndex = reserve
      .variableBorrowIndex;
    // 当前存款利率
    reserveCache.currLiquidityRate = reserve.currentLiquidityRate;
    // 当前浮动借款利率
    reserveCache.currVariableBorrowRate = reserve.currentVariableBorrowRate;

    reserveCache.aTokenAddress = reserve.aTokenAddress;
    reserveCache.stableDebtTokenAddress = reserve.stableDebtTokenAddress;
    reserveCache.variableDebtTokenAddress = reserve.variableDebtTokenAddress;

    reserveCache.reserveLastUpdateTimestamp = reserve.lastUpdateTimestamp;
    // 当前可变利率贷款总额
    reserveCache.currScaledVariableDebt = reserveCache.nextScaledVariableDebt = IVariableDebtToken(
      reserveCache.variableDebtTokenAddress
    ).scaledTotalSupply();

    (
      reserveCache.currPrincipalStableDebt, // 当前已固定利率借入的本金(只是代币发行量)
      reserveCache.currTotalStableDebt, // 当前以固定利率借出的总资产(即本金与利息之和)
      reserveCache.currAvgStableBorrowRate, // 平均固定利率
      reserveCache.stableDebtLastUpdateTimestamp // 固定利率更新时间
    ) = IStableDebtToken(reserveCache.stableDebtTokenAddress).getSupplyData();

    // by default the actions are considered as not affecting the debt balances.
    // if the action involves mint/burn of debt, the cache needs to be updated
    // 此种类型缓存仅为了方便后期进行数据更新
    reserveCache.nextTotalStableDebt = reserveCache.currTotalStableDebt;
    reserveCache.nextAvgStableBorrowRate = reserveCache.currAvgStableBorrowRate;

    return reserveCache;
  }
}
