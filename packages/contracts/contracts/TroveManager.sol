// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import './Dependencies/LiquityBase.sol';
import './Dependencies/CheckContract.sol';
import './Interfaces/ITroveManager.sol';
import './Interfaces/IDebtToken.sol';
import './Interfaces/IPriceFeed.sol';
import './Interfaces/IStoragePool.sol';
import './Interfaces/IBBase.sol';
import './Interfaces/ISortedTroves.sol';

contract TroveManager is LiquityBase, Ownable(msg.sender), CheckContract, ITroveManager {
  string public constant NAME = 'TroveManager';

  // --- Connected contract declarations ---

  address public borrowerOperationsAddress;
  address public redemptionOperationsAddress;
  address public liquidationOperationsAddress;
  IStoragePool public storagePool;
  IPriceFeed public priceFeed;
  ISortedTroves public sortedTroves;

  // --- Data structures ---

  /*
   * Half-life of 12h. 12h = 720 min
   * (1/2) = d^720 => d = (1/2)^(1/720)
   */
  uint public constant MINUTE_DECAY_FACTOR = 999037758833783000;

  // During bootsrap period redemptions are not allowed
  uint public constant BOOTSTRAP_PERIOD = 14 days;

  /*
   * BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
   * Corresponds to (1 / ALPHA) in the white paper.
   */
  uint public constant BETA = 2;
  uint public stableCoinBaseRate;

  // The timestamp of the latest fee operation (redemption or new dToken issuance)
  uint public lastFeeOperationTime;

  // Store the neccessary data for a trove
  struct Trove {
    Status status;
    uint128 arrayIndex;
    //
    IDebtToken[] debtTokens;
    mapping(address => bool) debtsRegistered;
    mapping(IDebtToken => uint) debts;
    //
    address[] collTokens;
    mapping(address => bool) collsRegistered;
    mapping(address => uint) colls;
    //
    // the troves stake is depends on the current collateral token prices
    // therefore the partial stakes relative to the collateral needs to be stored
    mapping(address => uint) stakes; // [collTokenAddress] -> stake
  }
  mapping(address => Trove) public Troves;

  // stakes gets stored relative to the coll token, total stake needs to be calculated on runtime using token prices
  // in token amount (not usd)
  mapping(address => uint) public totalStakes; // [collTokenAddress] => total system stake, relative to the coll token
  mapping(address => uint) public totalStakesSnapshot; // [collTokenAddress] => system stake, taken immediately after the latest liquidation (without default pool / rewards)
  mapping(address => uint) public totalCollateralSnapshots; // [collTokenAddress] => system stake, taken immediately after the latest liquidation (including default pool / rewards)

  // L_Tokens track the sums of accumulated liquidation rewards per unit staked. During its lifetime, each stake earns:
  // A gain of ( stake * [L_TOKEN[T] - L_TOKEN[T](0)] )
  // Where L_TOKEN[T](0) are snapshots of token T for the active Trove taken at the instant the stake was made
  //
  // in token amount (not usd)
  mapping(address => mapping(bool => uint)) public liquidatedTokens; // [tokenAddress][isColl] -> liquidated/redistributed amount, per unit staked
  mapping(address => mapping(address => mapping(bool => uint))) public rewardSnapshots; // [user][tokenAddress][isColl] -> value, snapshot amount, per unit staked
  mapping(address => mapping(bool => uint)) public lastErrorRedistribution; // [tokenAddress][isColl] -> value, Error trackers for the trove redistribution calculation

  // Array of all active trove addresses - used to to compute an approximate hint off-chain, for the sorted list insertion
  address[] public TroveOwners;

  // --- Dependency setter ---

  function setAddresses(
    address _borrowerOperationsAddress,
    address _redemptionOperationsAddress,
    address _liquidationOperationsAddress,
    address _storagePoolAddress,
    address _priceFeedAddress,
    address _sortedTrovesAddress
  ) external onlyOwner {
    checkContract(_borrowerOperationsAddress);
    checkContract(_redemptionOperationsAddress);
    checkContract(_liquidationOperationsAddress);
    checkContract(_storagePoolAddress);
    checkContract(_priceFeedAddress);
    checkContract(_sortedTrovesAddress);

    borrowerOperationsAddress = _borrowerOperationsAddress;
    redemptionOperationsAddress = _redemptionOperationsAddress;
    liquidationOperationsAddress = _liquidationOperationsAddress;
    storagePool = IStoragePool(_storagePoolAddress);
    priceFeed = IPriceFeed(_priceFeedAddress);
    sortedTroves = ISortedTroves(_sortedTrovesAddress);

    emit TroveManagerInitialized(
      _borrowerOperationsAddress,
      _redemptionOperationsAddress,
      _liquidationOperationsAddress,
      _storagePoolAddress,
      _priceFeedAddress,
      _sortedTrovesAddress
    );

    renounceOwnership();
  }

  /**
   *
   * troves status
   *
   **/

  function getTroveOwnersCount() external view override returns (uint) {
    return TroveOwners.length;
  }

  function getTroveOwners() external view returns (address[] memory) {
    return TroveOwners;
  }

  function getTroveStatus(address _borrower) external view override returns (uint) {
    return uint(Troves[_borrower].status);
  }

  function isTroveActive(address _borrower) external view override returns (bool) {
    return Troves[_borrower].status == Status.active;
  }

  function setTroveStatus(address _borrower, uint _num) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();
    Troves[_borrower].status = Status(_num);
  }

  /**
   *
   * collateral ratios
   *
   **/

  // Return the current collateral ratio (ICR) of a given Trove. Takes a trove's pending coll and debt rewards from redistributions into account.
  function getCurrentICR(address _borrower) external view override returns (uint ICR, uint currentDebtInUSD) {
    PriceCache memory priceCache = priceFeed.buildPriceCache();
    return _getCurrentICR(priceCache, _borrower);
  }

  function getCurrentICR(
    PriceCache memory _priceCache,
    address _borrower
  ) external view override returns (uint ICR, uint currentDebtInUSD) {
    return _getCurrentICR(_priceCache, _borrower);
  }

  function _getCurrentICR(
    PriceCache memory _priceCache,
    address _borrower
  ) internal view returns (uint ICR, uint currentDebtInUSD) {
    uint currentCollInUSD;
    (currentCollInUSD, currentDebtInUSD) = _getCurrentTrovesUSDValues(_priceCache, _borrower);
    ICR = LiquityMath._computeCR(currentCollInUSD, currentDebtInUSD);
    return (ICR, currentDebtInUSD);
  }

  function getICRIncludingPatch(
    address _borrower,
    TokenAmount[] memory addedColl,
    TokenAmount[] memory removedColl,
    TokenAmount[] memory addedDebt,
    TokenAmount[] memory removedDebt
  ) external view override returns (uint ICR) {
    Trove storage _trove = Troves[_borrower];
    if (_trove.status != Status.active) return 0;

    PriceCache memory priceCache = priceFeed.buildPriceCache();
    (uint currentCollInUSD, uint currentDebtInUSD) = _getCurrentTrovesUSDValues(priceCache, _borrower);

    currentCollInUSD += _getCompositeUSD(priceCache, addedColl);
    uint removedCollInUSD = _getCompositeUSD(priceCache, removedColl);
    if (currentCollInUSD < removedCollInUSD) currentCollInUSD = 0;
    else currentCollInUSD -= _getCompositeUSD(priceCache, removedColl);

    currentDebtInUSD += _getCompositeUSD(priceCache, addedDebt);
    uint removedDebtInUSD = _getCompositeUSD(priceCache, removedDebt);
    if (currentDebtInUSD < removedDebtInUSD) currentDebtInUSD = 0;
    else currentDebtInUSD -= _getCompositeUSD(priceCache, removedDebt);

    return LiquityMath._computeCR(currentCollInUSD, currentDebtInUSD);
  }

  function _getCompositeUSD(
    PriceCache memory _priceCache,
    TokenAmount[] memory _amounts
  ) internal view returns (uint inUSD) {
    for (uint i = 0; i < _amounts.length; i++)
      inUSD += priceFeed.getUSDValue(_priceCache, _amounts[i].tokenAddress, _amounts[i].amount);
    return inUSD;
  }

  function _getCurrentTrovesUSDValues(
    PriceCache memory _priceCache,
    address _borrower
  ) internal view returns (uint currentCollInUSD, uint currentDebtInUSD) {
    Trove storage _trove = Troves[_borrower];

    for (uint i = 0; i < _trove.collTokens.length; i++) {
      address token = _trove.collTokens[i];

      uint pendingRewards = _getPendingReward(_priceCache, _borrower, token, true);
      currentCollInUSD += priceFeed.getUSDValue(_priceCache, token, _trove.colls[token] + pendingRewards);
    }

    for (uint i = 0; i < _trove.debtTokens.length; i++) {
      IDebtToken token = _trove.debtTokens[i];

      uint pendingRewards = _getPendingReward(_priceCache, _borrower, address(token), true);
      currentDebtInUSD += priceFeed.getUSDValue(_priceCache, address(token), _trove.debts[token] + pendingRewards);
    }

    return (currentCollInUSD, currentDebtInUSD);
  }

  /**
   *
   * collateral stakes
   *
   **/

  // Update borrower's stake based on their latest collateral value
  function updateStakeAndTotalStakes(PriceCache memory _priceCache, address _borrower) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    TokenAmount[] memory totalStakesCopy = new TokenAmount[](_priceCache.collPrices.length);
    for (uint i = 0; i < _priceCache.collPrices.length; i++) {
      address _collAddress = _priceCache.collPrices[i].tokenAddress;

      uint newBorrowerCollStake;
      uint borrowersCollAmount = Troves[_borrower].colls[_collAddress];

      uint totalCollateralSnapshot = totalCollateralSnapshots[_collAddress];
      if (totalCollateralSnapshot == 0) newBorrowerCollStake = borrowersCollAmount;
      else {
        /*
         * The following assert() holds true because:
         * - The system always contains >= 1 trove
         * - When we close or liquidate a trove, we redistribute the pending rewards, so if all troves were closed/liquidated,
         * rewards would’ve been emptied and totalCollateralSnapshot would be zero too.
         */
        uint stakedSnapshot = totalStakesSnapshot[_collAddress];
        assert(stakedSnapshot > 0);
        newBorrowerCollStake = (borrowersCollAmount * stakedSnapshot) / totalCollateralSnapshot;
      }

      uint oldBorrowerStake = Troves[_borrower].stakes[_collAddress];
      uint newTotalStake = totalStakes[_collAddress] - oldBorrowerStake + newBorrowerCollStake;
      totalStakes[_collAddress] = newTotalStake;
      totalStakesCopy[i] = TokenAmount(_collAddress, newTotalStake);
      Troves[_borrower].stakes[_collAddress] = newBorrowerCollStake;
    }

    emit TotalStakesUpdated(totalStakesCopy);
  }

  // Remove borrower's stake from the totalStakes sum, and set their stake to 0
  function removeStake(PriceCache memory _priceCache, address _borrower) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    for (uint i = 0; i < _priceCache.collPrices.length; i++) {
      address tokenAddress = _priceCache.collPrices[i].tokenAddress;

      totalStakes[tokenAddress] -= Troves[_borrower].stakes[tokenAddress];
      Troves[_borrower].stakes[tokenAddress] = 0;
    }
  }

  /*
   * Updates snapshots of system total stakes and total collateral, excluding a given collateral remainder from the calculation.
   * Used in a liquidation sequence.
   */
  function updateSystemSnapshots_excludeCollRemainder(TokenAmount[] memory totalCollGasCompensation) external override {
    TokenAmount[] memory _totalStakesSnapshot = new TokenAmount[](totalCollGasCompensation.length);
    TokenAmount[] memory _totalCollateralSnapshots = new TokenAmount[](totalCollGasCompensation.length);

    // totalCollGasCompensation array included every available coll in the system, even if there is 0 gas compensation
    for (uint i = 0; i < totalCollGasCompensation.length; i++) {
      address tokenAddress = totalCollGasCompensation[i].tokenAddress;

      uint totalStake = totalStakes[tokenAddress];
      totalStakesSnapshot[tokenAddress] = totalStake;
      _totalStakesSnapshot[i] = TokenAmount(tokenAddress, totalStake);

      uint totalCollateralSnapshot = storagePool.getValue(tokenAddress, true, PoolType.Active) +
        storagePool.getValue(tokenAddress, true, PoolType.Default) -
        totalCollGasCompensation[i].amount;
      totalCollateralSnapshots[tokenAddress] = totalCollateralSnapshot;
      _totalCollateralSnapshots[i] = TokenAmount(tokenAddress, totalCollateralSnapshot);
    }

    emit SystemSnapshotsUpdated(_totalStakesSnapshot, _totalCollateralSnapshots);
  }

  /**
   * @notice Get Borrower's staked token amount, not in USD value
   * @param _borrower Address of borrower
   * @param _token Address of collateral token
   * @return stakes Staked amount of given collateral token of user
   */
  function getTroveStakes(address _borrower, address _token) external view override returns (uint) {
    return Troves[_borrower].stakes[_token];
  }

  /**
   * @notice Return borrowers staked value in USD
   * @param _borrower Address of borrower
   * @return stakedUSDValue USD value of total staked collaterals of borrower
   */
  function getTroveStakeValue(address _borrower) external view override returns (uint) {
    PriceCache memory _priceCache = priceFeed.buildPriceCache();
    return _calculateTrovesStake(_priceCache, _borrower);
  }

  // the current stake of the trove is depended on the current collateral prices
  function _calculateTrovesStake(PriceCache memory _priceCache, address _borrower) internal view returns (uint stake) {
    Trove storage trove = Troves[_borrower];

    for (uint i = 0; i < trove.collTokens.length; i++) {
      address tokenAddress = trove.collTokens[i];
      stake += priceFeed.getUSDValue(_priceCache, tokenAddress, trove.stakes[tokenAddress]);
    }

    return stake;
  }

  /**
   *
   * redistribution
   *
   **/

  function redistributeDebtAndColl(PriceCache memory _priceCache, CAmount[] memory toRedistribute) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    /*
     * Add distributed coll and debt rewards-per-unit-staked to the running totals. Division uses a "feedback"
     * error correction, to keep the cumulative error low in the running totals:
     *
     * 1) Form numerators which compensate for the floor division errors that occurred the last time this
     * function was called.
     * 2) Calculate "per-unit-staked" ratios.
     * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
     * 4) Store these errors for use in the next correction when this function is called.
     * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
     */

    uint totalStake = _getTotalStakesValue(_priceCache);
    CAmount[] memory _liquidatedTokens = new CAmount[](toRedistribute.length);

    for (uint i = 0; i < toRedistribute.length; i++) {
      CAmount memory redistributeEntry = toRedistribute[i];
      if (redistributeEntry.amount == 0) continue;

      // Get the per-unit-staked terms
      uint numerator = redistributeEntry.amount *
        DECIMAL_PRECISION +
        lastErrorRedistribution[redistributeEntry.tokenAddress][redistributeEntry.isColl];
      uint rewardPerUnitStaked = numerator / totalStake;

      lastErrorRedistribution[redistributeEntry.tokenAddress][redistributeEntry.isColl] =
        numerator -
        (rewardPerUnitStaked * totalStake);

      // Add per-unit-staked terms to the running totals
      uint liquidated = liquidatedTokens[redistributeEntry.tokenAddress][redistributeEntry.isColl] +
        rewardPerUnitStaked;

      liquidatedTokens[redistributeEntry.tokenAddress][redistributeEntry.isColl] = liquidated;
      _liquidatedTokens[i] = CAmount(redistributeEntry.tokenAddress, redistributeEntry.isColl, liquidated);

      storagePool.transferBetweenTypes(
        redistributeEntry.tokenAddress,
        redistributeEntry.isColl,
        PoolType.Active,
        PoolType.Default,
        redistributeEntry.amount
      );
    }

    emit LTermsUpdated(_liquidatedTokens);
  }

  function _getTotalStakesValue(PriceCache memory _priceCache) internal view returns (uint stake) {
    for (uint i = 0; i < _priceCache.collPrices.length; i++) {
      TokenPrice memory tokenPrice = _priceCache.collPrices[i];
      stake += priceFeed.getUSDValue(tokenPrice, totalStakes[tokenPrice.tokenAddress]);
    }

    return stake;
  }

  // Get the borrower's pending accumulated rewards, earned by their stake through their redistribution
  function getPendingReward(
    address _borrower,
    address _tokenAddress,
    bool _isColl
  ) public view override returns (uint pendingReward) {
    PriceCache memory _priceCache = priceFeed.buildPriceCache();
    return _getPendingReward(_priceCache, _borrower, _tokenAddress, _isColl);
  }

  function _getPendingReward(
    PriceCache memory _priceCache,
    address _borrower,
    address _tokenAddress,
    bool _isColl
  ) internal view returns (uint pendingReward) {
    uint snapshotValue = rewardSnapshots[_borrower][_tokenAddress][_isColl];
    uint rewardPerUnitStaked = liquidatedTokens[_tokenAddress][_isColl] - snapshotValue;
    if (rewardPerUnitStaked == 0 || Troves[_borrower].status != Status.active) return 0;

    uint trovesStakeInUSD = _calculateTrovesStake(_priceCache, _borrower);
    pendingReward = (trovesStakeInUSD * rewardPerUnitStaked) / DECIMAL_PRECISION;
  }

  function applyPendingRewards(address _borrower) external override {
    PriceCache memory _priceCache = priceFeed.buildPriceCache();
    return _applyPendingRewards(_priceCache, _borrower);
  }

  function applyPendingRewards(PriceCache memory _priceCache, address _borrower) external override {
    return _applyPendingRewards(_priceCache, _borrower);
  }

  function _applyPendingRewards(PriceCache memory _priceCache, address _borrower) internal {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();
    _requireTroveIsActive(_borrower);

    Trove storage _trove = Troves[_borrower];
    CAmount[] memory appliedRewards = new CAmount[](_trove.collTokens.length + _trove.debtTokens.length);

    // coll rewards
    for (uint i = 0; i < _trove.collTokens.length; i++) {
      address token = _trove.collTokens[i];

      uint pendingRewards = _getPendingReward(_priceCache, _borrower, token, true);
      appliedRewards[i] = CAmount(token, true, pendingRewards);
      if (pendingRewards == 0) continue;

      _trove.colls[token] += pendingRewards;
      storagePool.transferBetweenTypes(token, true, PoolType.Default, PoolType.Active, pendingRewards);
    }

    // debt rewards
    for (uint i = 0; i < _trove.debtTokens.length; i++) {
      IDebtToken token = _trove.debtTokens[i];
      address tokenAddress = address(token);

      uint pendingRewards = _getPendingReward(_priceCache, _borrower, tokenAddress, false);
      appliedRewards[_trove.collTokens.length + i] = CAmount(tokenAddress, false, pendingRewards);
      if (pendingRewards == 0) continue;

      _trove.debts[token] += pendingRewards;
      storagePool.transferBetweenTypes(tokenAddress, false, PoolType.Default, PoolType.Active, pendingRewards);
    }

    emit TroveAppliedRewards(_borrower, appliedRewards);
    _updateTroveRewardSnapshots(_borrower);
  }

  // Update borrower's snapshots to reflect the current values
  function updateTroveRewardSnapshots(address _borrower) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();
    return _updateTroveRewardSnapshots(_borrower);
  }

  function _updateTroveRewardSnapshots(address _borrower) internal {
    Trove storage _trove = Troves[_borrower];
    CAmount[] memory _troveSnapshots = new CAmount[](_trove.collTokens.length + _trove.debtTokens.length);

    for (uint i = 0; i < _trove.debtTokens.length; i++) {
      address token = address(_trove.debtTokens[i]);

      uint snapshot = liquidatedTokens[token][false];
      rewardSnapshots[_borrower][token][false] = snapshot;
      _troveSnapshots[i] = CAmount(token, false, snapshot);
    }
    for (uint i = 0; i < _trove.collTokens.length; i++) {
      address token = _trove.collTokens[i];

      uint snapshot = liquidatedTokens[token][true];
      rewardSnapshots[_borrower][token][true] = snapshot;
      _troveSnapshots[_trove.debtTokens.length + i] = CAmount(token, true, snapshot);
    }

    emit TroveSnapshotsUpdated(_troveSnapshots);
  }

  /**
   *
   * collateral and debt setters
   *
   **/

  function increaseTroveColl(address _borrower, TokenAmount[] memory _collTokenAmounts) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    Trove storage trove = Troves[_borrower];
    address[] memory collTokenAddresses = new address[](_collTokenAmounts.length);
    for (uint i = 0; i < _collTokenAmounts.length; i++) {
      address tokenAddress = _collTokenAmounts[i].tokenAddress;
      trove.colls[tokenAddress] += _collTokenAmounts[i].amount;

      if (!trove.collsRegistered[tokenAddress]) {
        trove.collsRegistered[tokenAddress] = true;
        trove.collTokens.push(tokenAddress);
      }
      collTokenAddresses[i] = tokenAddress;
    }

    emit TroveCollChanged(_borrower, collTokenAddresses);
  }

  function decreaseTroveColl(address _borrower, TokenAmount[] memory _collTokenAmounts) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    Trove storage trove = Troves[_borrower];
    address[] memory collTokenAddresses = new address[](_collTokenAmounts.length);

    for (uint i = 0; i < _collTokenAmounts.length; i++) {
      address tokenAddress = _collTokenAmounts[i].tokenAddress;
      trove.colls[tokenAddress] -= _collTokenAmounts[i].amount;
      collTokenAddresses[i] = tokenAddress;
    }

    emit TroveCollChanged(_borrower, collTokenAddresses);
  }

  function increaseTroveDebt(address _borrower, DebtTokenAmount[] memory _debtTokenAmounts) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    Trove storage trove = Troves[_borrower];
    for (uint i = 0; i < _debtTokenAmounts.length; i++) {
      IDebtToken debtToken = _debtTokenAmounts[i].debtToken;
      trove.debts[debtToken] += _debtTokenAmounts[i].netDebt;

      if (!trove.debtsRegistered[address(debtToken)]) {
        trove.debtsRegistered[address(debtToken)] = true;
        trove.debtTokens.push(debtToken);
      }
    }
  }

  function decreaseTroveDebt(address _borrower, DebtTokenAmount[] memory _debtTokenAmounts) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    Trove storage trove = Troves[_borrower];
    for (uint i = 0; i < _debtTokenAmounts.length; i++) {
      trove.debts[_debtTokenAmounts[i].debtToken] -= _debtTokenAmounts[i].netDebt;
    }
  }

  /**
   *
   * trove debt + coll getters
   *
   **/

  // Return the Troves entire debt and coll, including pending rewards from redistributions.
  function getEntireDebtAndColl(
    PriceCache memory _priceCache,
    address _borrower
  )
    external
    view
    override
    returns (
      RAmount[] memory amounts,
      uint troveCollInUSD,
      uint troveDebtInUSD,
      uint troveDebtInUSDWithoutGasCompensation
    )
  {
    Trove storage trove = Troves[_borrower];
    amounts = new RAmount[](trove.collTokens.length + trove.debtTokens.length);

    // initialize empty coll tokens
    for (uint i = 0; i < trove.collTokens.length; i++) {
      address token = address(trove.collTokens[i]);
      amounts[i] = RAmount(token, true, trove.colls[trove.collTokens[i]], 0, 0, 0, 0, 0, 0);
    }

    // initialize empty debt tokens and find the stable entry
    uint stableCoinIndex;
    for (uint i = 0; i < trove.debtTokens.length; i++) {
      if (trove.debtTokens[i].isStableCoin()) stableCoinIndex = i + trove.collTokens.length;

      address token = address(trove.debtTokens[i]);
      amounts[i + trove.collTokens.length] = RAmount(token, false, trove.debts[trove.debtTokens[i]], 0, 0, 0, 0, 0, 0);
    }

    // applying rewards (from default pool) + adding gas compensation + toLiquidate
    for (uint i = 0; i < amounts.length; i++) {
      RAmount memory amountEntry = amounts[i];

      amountEntry.pendingReward = _getPendingReward(
        _priceCache,
        _borrower,
        amountEntry.tokenAddress,
        amountEntry.isColl
      );
      uint totalAmount = amountEntry.amount + amountEntry.pendingReward;
      uint InUSD = priceFeed.getUSDValue(_priceCache, amountEntry.tokenAddress, totalAmount);

      if (amountEntry.isColl) {
        amountEntry.gasCompensation = _getCollGasCompensation(totalAmount);
        amountEntry.toLiquidate = totalAmount - amountEntry.gasCompensation;
        troveCollInUSD += InUSD;
      } else {
        if (i == stableCoinIndex) {
          // stable coin gas compensation should not be liquidated, it will be paid out as reward for the liquidator
          amountEntry.toLiquidate = totalAmount - STABLE_COIN_GAS_COMPENSATION;
          troveDebtInUSDWithoutGasCompensation += priceFeed.getUSDValue(
            _priceCache,
            amountEntry.tokenAddress,
            amountEntry.toLiquidate
          );
        } else {
          amountEntry.toLiquidate = totalAmount;
          troveDebtInUSDWithoutGasCompensation += InUSD;
        }

        troveDebtInUSD += InUSD;
      }
    }

    return (amounts, troveCollInUSD, troveDebtInUSD, troveDebtInUSDWithoutGasCompensation);
  }

  function getTroveDebt(address _borrower) public view override returns (TokenAmount[] memory) {
    Trove storage trove = Troves[_borrower];
    if (trove.status != Status.active) return new TokenAmount[](0);

    TokenAmount[] memory debts = new TokenAmount[](trove.debtTokens.length);
    for (uint i = 0; i < debts.length; i++)
      debts[i] = TokenAmount(address(trove.debtTokens[i]), trove.debts[trove.debtTokens[i]]);

    return debts;
  }

  function getTroveRepayableDebt(
    PriceCache memory _priceCache,
    address _borrower,
    address _debtTokenAddress,
    bool _includingStableCoinGasCompensation
  ) external view override returns (uint amount) {
    if (Troves[_borrower].status != Status.active) return 0;

    return _getTroveRepayableDebt(_priceCache, _borrower, _debtTokenAddress, _includingStableCoinGasCompensation);
  }

  function getTroveRepayableDebts(
    address _borrower,
    bool _includingStableCoinGasCompensation
  ) external view override returns (TokenAmount[] memory debts) {
    PriceCache memory _priceCache = priceFeed.buildPriceCache();
    return _getTroveRepayableDebts(_priceCache, _borrower, _includingStableCoinGasCompensation);
  }

  function getTroveRepayableDebts(
    PriceCache memory _priceCache,
    address _borrower,
    bool _includingStableCoinGasCompensation
  ) external view override returns (TokenAmount[] memory debts) {
    return _getTroveRepayableDebts(_priceCache, _borrower, _includingStableCoinGasCompensation);
  }

  function _getTroveRepayableDebts(
    PriceCache memory _priceCache,
    address _borrower,
    bool _includingStableCoinGasCompensation
  ) internal view returns (TokenAmount[] memory debts) {
    Trove storage trove = Troves[_borrower];
    if (trove.status != Status.active) return new TokenAmount[](0);

    address debtTokenAddress;
    debts = new TokenAmount[](trove.debtTokens.length);
    for (uint i = 0; i < debts.length; i++) {
      debtTokenAddress = address(trove.debtTokens[i]);
      debts[i] = TokenAmount(
        debtTokenAddress,
        _getTroveRepayableDebt(_priceCache, _borrower, debtTokenAddress, _includingStableCoinGasCompensation)
      );
    }

    return debts;
  }

  function _getTroveRepayableDebt(
    PriceCache memory _priceCache,
    address _borrower,
    address _debtTokenAddress,
    bool _includingStableCoinGasCompensation
  ) internal view returns (uint amount) {
    Trove storage trove = Troves[_borrower];
    if (trove.status != Status.active) return 0;

    return
      trove.debts[IDebtToken(_debtTokenAddress)] +
      _getPendingReward(_priceCache, _borrower, _debtTokenAddress, false) -
      (
        !_includingStableCoinGasCompensation && IDebtToken(_debtTokenAddress).isStableCoin()
          ? STABLE_COIN_GAS_COMPENSATION
          : 0
      );
  }

  function getTroveColl(address _borrower) public view override returns (TokenAmount[] memory colls) {
    Trove storage trove = Troves[_borrower];
    if (trove.status != Status.active) return new TokenAmount[](0);

    colls = new TokenAmount[](trove.collTokens.length);
    for (uint i = 0; i < colls.length; i++)
      colls[i] = TokenAmount(trove.collTokens[i], trove.colls[trove.collTokens[i]]);

    return colls;
  }

  function getTroveWithdrawableColl(
    address _borrower,
    address _collTokenAddress
  ) external view override returns (uint amount) {
    PriceCache memory _priceCache = priceFeed.buildPriceCache();
    return _getTroveWithdrawableColl(_priceCache, _borrower, _collTokenAddress);
  }

  function getTroveWithdrawableColl(
    PriceCache memory _priceCache,
    address _borrower,
    address _collTokenAddress
  ) external view override returns (uint amount) {
    return _getTroveWithdrawableColl(_priceCache, _borrower, _collTokenAddress);
  }

  function _getTroveWithdrawableColl(
    PriceCache memory _priceCache,
    address _borrower,
    address _collTokenAddress
  ) internal view returns (uint amount) {
    Trove storage trove = Troves[_borrower];
    if (trove.status != Status.active) return 0;

    return trove.colls[_collTokenAddress] + _getPendingReward(_priceCache, _borrower, _collTokenAddress, true);
  }

  function getTroveWithdrawableColls(address _borrower) external view override returns (TokenAmount[] memory colls) {
    PriceCache memory _priceCache = priceFeed.buildPriceCache();
    return _getTroveWithdrawableColls(_priceCache, _borrower);
  }

  function getTroveWithdrawableColls(
    PriceCache memory _priceCache,
    address _borrower
  ) external view override returns (TokenAmount[] memory colls) {
    return _getTroveWithdrawableColls(_priceCache, _borrower);
  }

  function _getTroveWithdrawableColls(
    PriceCache memory _priceCache,
    address _borrower
  ) internal view returns (TokenAmount[] memory colls) {
    colls = getTroveColl(_borrower);
    for (uint i = 0; i < colls.length; i++)
      colls[i].amount += _getPendingReward(_priceCache, _borrower, colls[i].tokenAddress, true);

    return colls;
  }

  /**
   *
   * trove opening + closing
   *
   **/

  // Push the owner's address to the Trove owners list, and record the corresponding array index on the Trove struct
  /* Max array size is 2**128 - 1, i.e. ~3e30 troves. 3e30 LUSD dwarfs the value of all wealth in the world ( which is < 1e15 USD). */
  function addTroveOwnerToArray(address _borrower) external override returns (uint128 index) {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    // Push the Troveowner to the array
    TroveOwners.push(_borrower);

    // Record the index of the new Troveowner on their Trove struct
    index = uint128(TroveOwners.length - 1);
    Troves[_borrower].arrayIndex = index;

    return index;
  }

  function closeTroveByProtocol(
    PriceCache memory _priceCache,
    address _borrower,
    Status closedStatus
  ) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    assert(closedStatus != Status.nonExistent && closedStatus != Status.active);

    uint numOfOwners = TroveOwners.length;
    if (numOfOwners <= 1) revert OnlyOneTrove();

    Trove storage trove = Troves[_borrower];
    trove.status = closedStatus;
    for (uint i = 0; i < trove.debtTokens.length; i++) {
      IDebtToken a = trove.debtTokens[i];
      trove.debts[a] = 0;
      trove.debtsRegistered[address(a)] = false;
    }
    for (uint i = 0; i < trove.collTokens.length; i++) {
      address a = trove.collTokens[i];
      trove.colls[a] = 0;
      trove.collsRegistered[a] = false;
    }
    for (uint i = 0; i < _priceCache.collPrices.length; i++) trove.stakes[_priceCache.collPrices[i].tokenAddress] = 0;
    delete trove.debtTokens;
    delete trove.collTokens;

    _removeTroveOwner(_borrower, numOfOwners);
    sortedTroves.remove(_borrower);
    emit TroveClosed(_borrower, closedStatus);
  }

  /*
   * Remove a Trove owner from the TroveOwners array, not preserving array order. Removing owner 'B' does the following:
   * [A B C D E] => [A E C D], and updates E's Trove struct to point to its new array index.
   */
  function _removeTroveOwner(address _borrower, uint _length) internal {
    Status troveStatus = Troves[_borrower].status;
    // It’s set in caller function `_closeTrove`
    assert(troveStatus != Status.nonExistent && troveStatus != Status.active);

    uint128 index = Troves[_borrower].arrayIndex;

    assert(index <= _length - 1);

    address addressToMove = TroveOwners[_length - 1];

    TroveOwners[index] = addressToMove;
    Troves[addressToMove].arrayIndex = index;
    emit TroveIndexUpdated(addressToMove, index);

    TroveOwners.pop();
  }

  /**
   *
   * Helper
   *
   **/

  function getStableCoinBaseRate() external view override returns (uint) {
    return stableCoinBaseRate;
  }

  function getBorrowingRate(bool isStableCoin) public view override returns (uint) {
    if (!isStableCoin) return BORROWING_FEE_FLOOR;
    return _calcBorrowingRate(stableCoinBaseRate);
  }

  function getBorrowingRateWithDecay(bool isStableCoin) public view override returns (uint) {
    if (!isStableCoin) return BORROWING_FEE_FLOOR;
    return _calcBorrowingRate(calcDecayedStableCoinBaseRate());
  }

  function _calcBorrowingRate(uint _stableCoinBaseRate) internal pure returns (uint) {
    return LiquityMath._min(BORROWING_FEE_FLOOR + _stableCoinBaseRate, MAX_BORROWING_FEE);
  }

  function getBorrowingFee(uint _debtValue, bool isStableCoin) external view override returns (uint) {
    return _calcBorrowingFee(getBorrowingRate(isStableCoin), _debtValue);
  }

  function getBorrowingFeeWithDecay(uint _debtValue, bool isStableCoin) external view override returns (uint) {
    return _calcBorrowingFee(getBorrowingRateWithDecay(isStableCoin), _debtValue);
  }

  function _calcBorrowingFee(uint _borrowingRate, uint _debtValue) internal pure returns (uint) {
    return (_borrowingRate * _debtValue) / DECIMAL_PRECISION;
  }

  // Updates the stableCoinBaseRate state variable based on time elapsed since the last redemption or stable borrowing operation.
  function decayStableCoinBaseRateFromBorrowing(uint borrowedStable) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    if (borrowedStable == 0) return; // only decay the stableCoinBaseRate if stable was borrowed (not stocks)

    uint decayedStableCoinBaseRate = calcDecayedStableCoinBaseRate();
    assert(decayedStableCoinBaseRate <= DECIMAL_PRECISION); // The stableCoinBaseRate can decay to 0
    _updateLastFeeOpTime(decayedStableCoinBaseRate);
  }

  /*
   * This function has two impacts on the stableCoinBaseRate state variable:
   * 1) decays the stableCoinBaseRate based on time passed since last redemption or stable coin borrowing operation.
   * then,
   * 2) increases the stableCoinBaseRate based on the amount redeemed, as a proportion of total supply
   */
  function updateStableCoinBaseRateFromRedemption(
    uint _totalRedeemedStable,
    uint _totalStableCoinSupply
  ) external override {
    _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps();

    uint decayedStableCoinBaseRate = calcDecayedStableCoinBaseRate();
    uint redeemedStableFraction = (_totalRedeemedStable * DECIMAL_PRECISION) / _totalStableCoinSupply;

    uint newStableCoinBaseRate = LiquityMath._min(
      decayedStableCoinBaseRate + (redeemedStableFraction / BETA),
      DECIMAL_PRECISION
    ); // cap stableCoinBaseRate at a maximum of 100%
    assert(newStableCoinBaseRate > 0); // Base rate is always non-zero after redemption
    _updateLastFeeOpTime(newStableCoinBaseRate);
  }

  // Update the last fee operation time only if time passed >= decay interval. This prevents base rate griefing.
  function _updateLastFeeOpTime(uint newStableCoinBaseRate) internal {
    stableCoinBaseRate = newStableCoinBaseRate; // Update the StableCoinBaseRate state variable
    emit StableCoinBaseRateUpdated(newStableCoinBaseRate);

    uint timePassed = block.timestamp - lastFeeOperationTime;
    if (timePassed >= 1 minutes) {
      lastFeeOperationTime = block.timestamp;
      emit LastFeeOpTimeUpdated(block.timestamp);
    }
  }

  function calcDecayedStableCoinBaseRate() public view override returns (uint) {
    uint minutesPassed = _minutesPassedSinceLastFeeOp();
    uint decayFactor = LiquityMath._decPow(MINUTE_DECAY_FACTOR, minutesPassed);

    return (stableCoinBaseRate * decayFactor) / DECIMAL_PRECISION;
  }

  function _minutesPassedSinceLastFeeOp() internal view returns (uint) {
    return (block.timestamp - lastFeeOperationTime) / 1 minutes;
  }

  function _requireCallerIsBorrowerOpsOrRedemptionOpsOrLiquidationOps() internal view {
    if (
      msg.sender != borrowerOperationsAddress &&
      msg.sender != redemptionOperationsAddress &&
      msg.sender != liquidationOperationsAddress
    ) revert NotFromBorrowerOrRedemptionOps();
  }

  function _requireTroveIsActive(address _borrower) internal view {
    if (Troves[_borrower].status != Status.active) revert InvalidTrove();
  }
}
