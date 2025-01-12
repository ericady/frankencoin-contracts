// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import './Dependencies/LiquityBase.sol';
import './Dependencies/CheckContract.sol';
import './Interfaces/IBorrowerOperations.sol';
import './Interfaces/ITroveManager.sol';
import './Interfaces/IDebtToken.sol';
import './Interfaces/ITokenManager.sol';
import './Interfaces/IStoragePool.sol';
import './Interfaces/IReservePool.sol';
import './Interfaces/IPriceFeed.sol';
import './Interfaces/IBBase.sol';
import './Interfaces/ISortedTroves.sol';
import './Interfaces/ICollSurplusPool.sol';

contract BorrowerOperations is LiquityBase, Ownable(msg.sender), CheckContract, IBorrowerOperations {
  string public constant NAME = 'BorrowerOperations';

  // --- Connected contract declarations ---

  ITroveManager public troveManager;
  ITokenManager public tokenManager;
  IStoragePool public storagePool;
  IReservePool public reservePool;
  IPriceFeed public priceFeed;
  ISortedTroves public sortedTroves;
  ICollSurplusPool public collSurplusPool;
  address stabilityPoolAddress;
  address swapOperations;

  /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

  struct LocalVariables_openTrove {
    PriceCache priceCache;
    //
    TokenAmount[] colls;
    DebtTokenAmount[] debts;
    uint compositeDebtInUSD;
    uint compositeCollInUSD;
    uint ICR;
    uint arrayIndex;
    //
    bool isInRecoveryMode;
    uint TCR;
    uint entireSystemColl;
    uint entireSystemDebt;
  }

  struct LocalVariables_adjustTrove {
    PriceCache priceCache;
    //
    TokenAmount[] colls;
    DebtTokenAmount[] debts;
    DebtTokenAmount stableCoinEntry;
    //
    uint oldCompositeDebtInUSD;
    uint oldCompositeCollInUSD;
    uint oldICR;
    //
    uint newCompositeDebtInUSD;
    uint newCompositeCollInUSD;
    uint newICR;
    uint remainingStableDebt;
    //
    bool isInRecoveryMode;
    uint entireSystemColl;
    uint entireSystemDebt;
  }

  struct LocalVariables_closeTrove {
    PriceCache priceCache;
    //
    bool isInRecoveryMode;
    uint newTCR;
    uint entireSystemColl;
    uint entireSystemDebt;
  }

  struct ContractsCache {
    ITroveManager troveManager;
    IStoragePool storagePool;
    ITokenManager tokenManager;
    IPriceFeed priceFeed;
  }

  // --- Dependency setters ---

  function setAddresses(
    address _troveManagerAddress,
    address _storagePoolAddress,
    address _stabilityPoolAddress,
    address _reservePoolAddress,
    address _priceFeedAddress,
    address _tokenManagerAddress,
    address _swapOperationsAddress,
    address _sortedTrovesAddress,
    address _collSurplusPoolAddress
  ) external onlyOwner {
    checkContract(_troveManagerAddress);
    checkContract(_storagePoolAddress);
    checkContract(_stabilityPoolAddress);
    checkContract(_reservePoolAddress);
    checkContract(_priceFeedAddress);
    checkContract(_tokenManagerAddress);
    checkContract(_swapOperationsAddress);
    checkContract(_sortedTrovesAddress);
    checkContract(_collSurplusPoolAddress);

    troveManager = ITroveManager(_troveManagerAddress);
    storagePool = IStoragePool(_storagePoolAddress);
    stabilityPoolAddress = _stabilityPoolAddress;
    reservePool = IReservePool(_reservePoolAddress);
    priceFeed = IPriceFeed(_priceFeedAddress);
    tokenManager = ITokenManager(_tokenManagerAddress);
    swapOperations = _swapOperationsAddress;
    sortedTroves = ISortedTroves(_sortedTrovesAddress);
    collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);

    emit BorrowerOperationsInitialized(
      _troveManagerAddress,
      _storagePoolAddress,
      _stabilityPoolAddress,
      _reservePoolAddress,
      _priceFeedAddress,
      _tokenManagerAddress,
      _swapOperationsAddress,
      _sortedTrovesAddress,
      _collSurplusPoolAddress
    );

    renounceOwnership();
  }

  // --- Borrower Trove Operations ---

  function openTrove(TokenAmount[] memory _colls) public override {
    _openTrove(msg.sender, _colls);
  }

  function _openTrove(address borrower, TokenAmount[] memory _colls) internal {
    ContractsCache memory contractsCache = ContractsCache(troveManager, storagePool, tokenManager, priceFeed);
    _requireTroveIsNotActive(contractsCache.troveManager, borrower);

    LocalVariables_openTrove memory vars;
    vars.priceCache = contractsCache.priceFeed.buildPriceCache();
    (vars.isInRecoveryMode, , vars.entireSystemColl, vars.entireSystemDebt) = contractsCache
      .storagePool
      .checkRecoveryMode(vars.priceCache);

    // adding gas compensation to the net debt
    DebtTokenAmount memory stableCoinAmount = DebtTokenAmount(
      contractsCache.tokenManager.getStableCoin(),
      STABLE_COIN_GAS_COMPENSATION,
      0
    );
    vars.debts = new DebtTokenAmount[](1);
    vars.debts[0] = stableCoinAmount;
    vars.compositeDebtInUSD = _getCompositeDebt(contractsCache.priceFeed, vars.priceCache, vars.debts);
    vars.colls = _colls;
    vars.compositeCollInUSD = _getCompositeColl(contractsCache.priceFeed, vars.priceCache, vars.colls);

    // ICR is based on the composite debt, i.e. the requested debt amount + borrowing fee + debt gas comp.
    vars.ICR = LiquityMath._computeCR(vars.compositeCollInUSD, vars.compositeDebtInUSD);

    if (vars.isInRecoveryMode) {
      _requireICRisAboveCCR(vars.ICR); // > 150 %
    } else {
      _requireICRisAboveMCR(vars.ICR); // > 110 %

      uint newTCR = _getNewTCRFromTroveChange(
        vars.compositeCollInUSD,
        true,
        vars.compositeDebtInUSD,
        true,
        vars.entireSystemColl,
        vars.entireSystemDebt
      ); // bools: coll increase, debt increase
      _requireNewTCRisAboveCCR(newTCR); // > 150 %
    }

    // Set the trove struct's properties
    contractsCache.troveManager.setTroveStatus(borrower, 1); // active
    contractsCache.troveManager.increaseTroveColl(borrower, vars.colls);
    contractsCache.troveManager.increaseTroveDebt(borrower, vars.debts);
    contractsCache.troveManager.updateTroveRewardSnapshots(borrower);
    contractsCache.troveManager.updateStakeAndTotalStakes(vars.priceCache, borrower);

    // just adding the trove to the general list, but not the sorted one, cause no redeemable stable debt yet
    vars.arrayIndex = contractsCache.troveManager.addTroveOwnerToArray(borrower);

    // Move the coll to the active pool
    for (uint i = 0; i < vars.colls.length; i++) {
      TokenAmount memory collTokenAmount = vars.colls[i];
      _poolAddColl(
        borrower,
        contractsCache.storagePool,
        collTokenAmount.tokenAddress,
        collTokenAmount.amount,
        PoolType.Active
      );
    }

    // Move the stable coin gas compensation to the Gas Pool
    contractsCache.storagePool.addValue(
      address(stableCoinAmount.debtToken),
      false,
      PoolType.GasCompensation,
      stableCoinAmount.netDebt
    );
    stableCoinAmount.debtToken.mint(address(contractsCache.storagePool), stableCoinAmount.netDebt);

    emit TroveCreated(borrower, _colls);
  }

  function openTroveWithPermit(
    TokenAmount[] memory _colls,
    uint deadline,
    uint8[] memory v,
    bytes32[] memory r,
    bytes32[] memory s
  ) external {
    for (uint i = 0; i < _colls.length; i++)
      IERC20Permit(_colls[i].tokenAddress).permit(
        msg.sender,
        address(this),
        _colls[i].amount,
        deadline,
        v[i],
        r[i],
        s[i]
      );

    openTrove(_colls);
  }

  // Send collateral to a trove
  function addColl(TokenAmount[] memory _colls, address _upperHint, address _lowerHint) public override {
    address borrower = msg.sender;
    (ContractsCache memory contractsCache, LocalVariables_adjustTrove memory vars) = _prepareTroveAdjustment(borrower);

    vars.newCompositeCollInUSD += _getCompositeColl(contractsCache.priceFeed, vars.priceCache, _colls);
    contractsCache.troveManager.increaseTroveColl(borrower, _colls);

    for (uint i = 0; i < _colls.length; i++) {
      TokenAmount memory collTokenAmount = _colls[i];
      _poolAddColl(
        borrower,
        contractsCache.storagePool,
        collTokenAmount.tokenAddress,
        collTokenAmount.amount,
        PoolType.Active
      );
    }

    _finaliseTrove(false, false, contractsCache, vars, borrower, _upperHint, _lowerHint);
  }

  function addCollWithPermit(
    TokenAmount[] memory _colls,
    uint deadline,
    uint8[] memory v,
    bytes32[] memory r,
    bytes32[] memory s,
    address _upperHint,
    address _lowerHint
  ) external {
    for (uint i = 0; i < _colls.length; i++) {
      IERC20Permit(_colls[i].tokenAddress).permit(
        msg.sender,
        address(this),
        _colls[i].amount,
        deadline,
        v[i],
        r[i],
        s[i]
      );
    }

    addColl(_colls, _upperHint, _lowerHint);
  }

  // Withdraw collateral from a trove
  function withdrawColl(TokenAmount[] memory _colls, address _upperHint, address _lowerHint) external override {
    address borrower = msg.sender;
    (ContractsCache memory contractsCache, LocalVariables_adjustTrove memory vars) = _prepareTroveAdjustment(borrower);

    uint withdrawCompositeInUSD = _getCompositeColl(contractsCache.priceFeed, vars.priceCache, _colls);
    if (withdrawCompositeInUSD > vars.newCompositeCollInUSD) revert WithdrawAmount_gt_Coll();
    vars.newCompositeCollInUSD -= withdrawCompositeInUSD;

    contractsCache.troveManager.decreaseTroveColl(borrower, _colls);

    for (uint i = 0; i < _colls.length; i++) {
      TokenAmount memory collTokenAmount = _colls[i];

      // checking is the trove has enough coll for the withdrawal
      TokenAmount memory existingColl;
      for (uint ii = 0; ii < vars.colls.length; ii++) {
        if (vars.colls[ii].tokenAddress != collTokenAmount.tokenAddress) continue;
        existingColl = vars.colls[ii];
        break;
      }
      assert(existingColl.amount >= collTokenAmount.amount);

      _poolSubtractColl(
        borrower,
        contractsCache.storagePool,
        collTokenAmount.tokenAddress,
        collTokenAmount.amount,
        PoolType.Active
      );
    }

    _finaliseTrove(true, false, contractsCache, vars, borrower, _upperHint, _lowerHint);
  }

  function increaseDebt(
    address _borrower,
    address _to,
    TokenAmount[] memory _debts,
    MintMeta memory _meta
  ) external override {
    _requireCallerIsSwapOperations();
    _increaseDebt(_borrower, _to, _debts, _meta);
  }

  // increasing debt off a trove
  function _increaseDebt(address _borrower, address _to, TokenAmount[] memory _debts, MintMeta memory _meta) internal {
    (ContractsCache memory contractsCache, LocalVariables_adjustTrove memory vars) = _prepareTroveAdjustment(_borrower);

    _requireValidMaxFeePercentage(_meta.maxFeePercentage, vars.isInRecoveryMode);
    for (uint i = 0; i < _debts.length; i++) {
      _requireNonZeroDebtChange(_debts[i].amount);

      // revert minting if one of the oracles is not trusted
      TokenPrice memory tokenPrice = contractsCache.priceFeed.getTokenPrice(vars.priceCache, _debts[i].tokenAddress);
      if (!tokenPrice.isPriceTrusted) revert UntrustedOraclesMintingIsFrozen(tokenPrice.tokenAddress);
    }

    (DebtTokenAmount[] memory debtsToAdd, DebtTokenAmount memory stableCoinAmount) = _getDebtTokenAmounts(
      contractsCache.tokenManager,
      _debts
    );

    // adding the borrowing fee to the net debt
    uint borrowingFeesPaid = 0;
    if (!vars.isInRecoveryMode)
      borrowingFeesPaid = _addBorrowingFees(
        contractsCache,
        vars.priceCache,
        debtsToAdd,
        stableCoinAmount,
        _meta.maxFeePercentage
      );

    vars.newCompositeDebtInUSD += _getCompositeDebt(contractsCache.priceFeed, vars.priceCache, debtsToAdd);
    contractsCache.troveManager.increaseTroveDebt(_borrower, debtsToAdd);

    for (uint i = 0; i < debtsToAdd.length; i++) {
      DebtTokenAmount memory debtTokenAmount = debtsToAdd[i];
      _poolAddDebt(
        _to,
        contractsCache.storagePool,
        debtTokenAmount.debtToken,
        debtTokenAmount.netDebt,
        debtTokenAmount.borrowingFee
      );
    }

    vars.remainingStableDebt += stableCoinAmount.netDebt; // added stable debt (including all fees)
    _finaliseTrove(false, true, contractsCache, vars, _borrower, _meta.upperHint, _meta.lowerHint);
  }

  // repay debt of a trove
  function repayDebt(TokenAmount[] memory _debts, address _upperHint, address _lowerHint) external override {
    address borrower = msg.sender;

    (ContractsCache memory contractsCache, LocalVariables_adjustTrove memory vars) = _prepareTroveAdjustment(borrower);
    (DebtTokenAmount[] memory debtsToRemove, DebtTokenAmount memory stableCoinEntry) = _handleRepayStates(
      contractsCache,
      vars,
      borrower,
      _debts
    );

    for (uint i = 0; i < debtsToRemove.length; i++) {
      DebtTokenAmount memory debtTokenAmount = debtsToRemove[i];
      _poolRepayDebt(
        borrower,
        contractsCache.storagePool,
        debtTokenAmount.debtToken,
        debtTokenAmount.netDebt // it is not possible to repay the gasComp, this happens only when the trove is closed
      );
    }

    vars.remainingStableDebt -= stableCoinEntry.netDebt;
    _finaliseTrove(false, false, contractsCache, vars, borrower, _upperHint, _lowerHint);
  }

  // repay debt of a trove directly from swap ops after pool liquidity removal (burning)
  // the debt tokens are directly burned from the swap ops
  function repayDebtFromPoolBurn(
    address borrower,
    TokenAmount[] memory _debts,
    address _upperHint,
    address _lowerHint
  ) external override {
    _requireCallerIsSwapOperations();

    (ContractsCache memory contractsCache, LocalVariables_adjustTrove memory vars) = _prepareTroveAdjustment(borrower);
    (DebtTokenAmount[] memory debtsToRemove, DebtTokenAmount memory stableCoinEntry) = _handleRepayStates(
      contractsCache,
      vars,
      borrower,
      _debts
    );

    for (uint i = 0; i < debtsToRemove.length; i++) {
      DebtTokenAmount memory debtTokenAmount = debtsToRemove[i];
      contractsCache.storagePool.subtractValue(
        address(debtTokenAmount.debtToken),
        false,
        PoolType.Active,
        debtTokenAmount.netDebt
      );
    }

    vars.remainingStableDebt -= stableCoinEntry.netDebt;
    _finaliseTrove(false, false, contractsCache, vars, borrower, _upperHint, _lowerHint);
  }

  function _handleRepayStates(
    ContractsCache memory contractsCache,
    LocalVariables_adjustTrove memory vars,
    address borrower,
    TokenAmount[] memory _debts
  ) internal returns (DebtTokenAmount[] memory debtsToRemove, DebtTokenAmount memory stableCoinEntry) {
    (debtsToRemove, stableCoinEntry) = _getDebtTokenAmounts(contractsCache.tokenManager, _debts);
    vars.newCompositeDebtInUSD -= _getCompositeDebt(contractsCache.priceFeed, vars.priceCache, debtsToRemove);
    contractsCache.troveManager.decreaseTroveDebt(borrower, debtsToRemove);

    for (uint i = 0; i < debtsToRemove.length; i++) {
      DebtTokenAmount memory debtTokenAmount = debtsToRemove[i];
      address debtTokenAddress = address(debtTokenAmount.debtToken);

      // check zero amount
      if (debtTokenAmount.netDebt == 0) revert ZeroDebtRepay();

      // checking if the trove has enough debt for the repayment (gas comp needs to remain)
      DebtTokenAmount memory existingDebt;
      for (uint ii = 0; ii < vars.debts.length; ii++) {
        if (address(vars.debts[ii].debtToken) != debtTokenAddress) continue;
        existingDebt = vars.debts[ii];
        break;
      }
      _requireAtLeastMinNetDebt(existingDebt.netDebt, debtTokenAmount.netDebt);

      if (debtTokenAmount.debtToken.isStableCoin())
        _requireValidStableCoinRepayment(existingDebt.netDebt, debtTokenAmount.netDebt);
    }

    return (debtsToRemove, stableCoinEntry);
  }

  function closeTrove() external override {
    address borrower = msg.sender;
    (ContractsCache memory contractsCache, LocalVariables_adjustTrove memory vars) = _prepareTroveAdjustment(borrower);

    _requireNotInRecoveryMode(vars.isInRecoveryMode);

    uint newTCR = _getNewTCRFromTroveChange(
      vars.oldCompositeCollInUSD,
      false,
      vars.oldCompositeDebtInUSD,
      false,
      vars.entireSystemColl,
      vars.entireSystemDebt
    );
    _requireNewTCRisAboveCCR(newTCR);

    // repay any open debts
    for (uint i = 0; i < vars.debts.length; i++) {
      DebtTokenAmount memory debtTokenAmount = vars.debts[i];

      uint toRepay;
      if (debtTokenAmount.debtToken.isStableCoin()) toRepay = debtTokenAmount.netDebt - STABLE_COIN_GAS_COMPENSATION;
      else toRepay = debtTokenAmount.netDebt;
      if (toRepay == 0) continue;

      _poolRepayDebt(borrower, contractsCache.storagePool, debtTokenAmount.debtToken, toRepay);
    }

    // burn the gas compensation
    _poolBurnGasComp(contractsCache.storagePool, vars.stableCoinEntry.debtToken);

    // Send the collateral back to the user
    for (uint i = 0; i < vars.colls.length; i++) {
      TokenAmount memory collTokenAmount = vars.colls[i];

      _poolSubtractColl(
        borrower,
        contractsCache.storagePool,
        collTokenAmount.tokenAddress,
        collTokenAmount.amount,
        PoolType.Active
      );
    }

    contractsCache.troveManager.removeStake(vars.priceCache, borrower);
    contractsCache.troveManager.closeTroveByProtocol(vars.priceCache, borrower, Status.closedByOwner);
  }

  /**
   * Claim remaining collateral from a redemption or from a liquidation with ICR > MCR in Recovery Mode
   */
  function claimCollateral() external override {
    collSurplusPool.claimColl(msg.sender);
  }

  // --- Helper functions ---

  function _prepareTroveAdjustment(
    address _borrower
  ) internal returns (ContractsCache memory contractsCache, LocalVariables_adjustTrove memory vars) {
    contractsCache = ContractsCache(troveManager, storagePool, tokenManager, priceFeed);

    vars.priceCache = contractsCache.priceFeed.buildPriceCache();
    (vars.isInRecoveryMode, , vars.entireSystemColl, vars.entireSystemDebt) = contractsCache
      .storagePool
      .checkRecoveryMode(vars.priceCache);

    _requireTroveIsActive(contractsCache.troveManager, _borrower);
    contractsCache.troveManager.applyPendingRewards(vars.priceCache, _borrower); // from redistributions

    // fetching old/current debts and colls including prices + calc ICR
    (vars.debts, vars.stableCoinEntry) = _getDebtTokenAmounts(
      contractsCache.tokenManager,
      contractsCache.troveManager.getTroveDebt(_borrower)
    );
    vars.remainingStableDebt = vars.stableCoinEntry.netDebt;
    vars.oldCompositeDebtInUSD = _getCompositeDebt(contractsCache.priceFeed, vars.priceCache, vars.debts);
    vars.newCompositeDebtInUSD = vars.oldCompositeDebtInUSD;

    vars.colls = contractsCache.troveManager.getTroveColl(_borrower);

    vars.oldCompositeCollInUSD = _getCompositeColl(contractsCache.priceFeed, vars.priceCache, vars.colls);
    vars.newCompositeCollInUSD = vars.oldCompositeCollInUSD;

    vars.oldICR = LiquityMath._computeCR(vars.oldCompositeCollInUSD, vars.oldCompositeDebtInUSD);
    return (contractsCache, vars);
  }

  function _finaliseTrove(
    bool _isCollWithdrawal,
    bool _isDebtIncrease,
    ContractsCache memory contractsCache,
    LocalVariables_adjustTrove memory vars,
    address _borrower,
    address _upperHint,
    address _lowerHint
  ) internal {
    // calculate the new ICR
    vars.newICR = LiquityMath._computeCR(vars.newCompositeCollInUSD, vars.newCompositeDebtInUSD);

    // Check the adjustment satisfies all conditions for the current system mode
    _requireValidAdjustmentInCurrentMode(_isCollWithdrawal, _isDebtIncrease, vars);

    // update troves stake
    contractsCache.troveManager.updateStakeAndTotalStakes(vars.priceCache, _borrower);

    // update the troves list position
    sortedTroves.update(
      _borrower,
      vars.newICR,
      vars.remainingStableDebt - STABLE_COIN_GAS_COMPENSATION,
      _upperHint,
      _lowerHint
    );
  }

  function _getNewTCRFromTroveChange(
    uint _collChange,
    bool _isCollIncrease,
    uint _debtChange,
    bool _isDebtIncrease,
    uint entireSystemColl,
    uint entireSystemDebt
  ) internal pure returns (uint) {
    uint totalColl = _isCollIncrease ? entireSystemColl + _collChange : entireSystemColl - _collChange;
    uint totalDebt = _isDebtIncrease ? entireSystemDebt + _debtChange : entireSystemDebt - _debtChange;

    uint newTCR = LiquityMath._computeCR(totalColl, totalDebt);
    return newTCR;
  }

  function _addBorrowingFees(
    ContractsCache memory _contractsCache,
    PriceCache memory _priceCache,
    DebtTokenAmount[] memory _debts,
    DebtTokenAmount memory _stableCoinAmount,
    uint _maxFeePercentage
  ) internal returns (uint borrowingFee) {
    _contractsCache.troveManager.decayStableCoinBaseRateFromBorrowing(_stableCoinAmount.netDebt); // decay the baseRate state variable

    TokenPrice memory stableCoinPrice = _contractsCache.priceFeed.getTokenPrice(
      _priceCache,
      address(_stableCoinAmount.debtToken)
    );
    uint compositeDebtInUSD = _getCompositeDebt(_contractsCache.priceFeed, _priceCache, _debts);
    uint stableCoinDebtInUSD = priceFeed.getUSDValue(stableCoinPrice, _stableCoinAmount.netDebt);

    borrowingFee =
      _contractsCache.troveManager.getBorrowingFee(compositeDebtInUSD - stableCoinDebtInUSD, false) +
      _contractsCache.troveManager.getBorrowingFee(stableCoinDebtInUSD, true);
    _requireUserAcceptsFee(borrowingFee, compositeDebtInUSD, _maxFeePercentage);

    // update troves debts
    borrowingFee = _contractsCache.priceFeed.getAmountFromUSDValue(stableCoinPrice, borrowingFee);
    _stableCoinAmount.netDebt += borrowingFee;
    _stableCoinAmount.borrowingFee += borrowingFee;
    return borrowingFee;
  }

  function _poolAddColl(
    address _borrower,
    IStoragePool _pool,
    address _collAddress,
    uint _amount,
    PoolType _poolType
  ) internal {
    _pool.addValue(_collAddress, true, _poolType, _amount);
    IERC20(_collAddress).transferFrom(_borrower, address(_pool), _amount);
  }

  function _poolSubtractColl(
    address _borrower,
    IStoragePool _pool,
    address _collAddress,
    uint _amount,
    PoolType _poolType
  ) internal {
    _pool.withdrawalValue(_borrower, _collAddress, true, _poolType, _amount);
  }

  function _poolAddDebt(
    address _tokenRecipient,
    IStoragePool _storagePool,
    IDebtToken _debtToken,
    uint _netDebtIncrease,
    uint _borrowingFee
  ) internal {
    _storagePool.addValue(address(_debtToken), false, PoolType.Active, _netDebtIncrease);

    // forward the borrowing fee to the reserve pool (or gov staking)
    if (_borrowingFee > 0) {
      uint govStakingPayout = _borrowingFee;
      uint missingStableForReserveCap = reservePool.stableAmountUntilCap();
      if (missingStableForReserveCap > 0) {
        uint reserveTransfer = LiquityMath._min(_borrowingFee, missingStableForReserveCap);
        govStakingPayout -= reserveTransfer;
        _debtToken.mint(address(reservePool), reserveTransfer);
      }
      if (govStakingPayout > 0) _debtToken.mint(GOV_STAKING_ADDRESS, govStakingPayout);
      emit PaidBorrowingFee(_tokenRecipient, _borrowingFee);
    }

    // payout issued debt to the recipient
    uint mintAmount = _netDebtIncrease - _borrowingFee;
    if (mintAmount > 0) _debtToken.mint(_tokenRecipient, mintAmount);
  }

  function _poolRepayDebt(
    address _borrower,
    IStoragePool _storagePool,
    IDebtToken _debtToken,
    uint _repayAmount
  ) internal {
    _requireSufficientDebtBalance(_debtToken, _borrower, _repayAmount);
    _storagePool.subtractValue(address(_debtToken), false, PoolType.Active, _repayAmount);
    _debtToken.burn(_borrower, _repayAmount);
  }

  function _poolBurnGasComp(IStoragePool _storagePool, IDebtToken _stableCoin) internal {
    _storagePool.subtractValue(address(_stableCoin), false, PoolType.GasCompensation, STABLE_COIN_GAS_COMPENSATION);
    _stableCoin.burn(address(_storagePool), STABLE_COIN_GAS_COMPENSATION);
  }

  // --- 'Require' wrapper functions ---

  function _requireCallerIsSwapOperations() internal view {
    if (msg.sender != swapOperations) revert NotFromSwapOps();
  }

  function _requireCallerIsBorrower(address _borrower) internal view {
    if (msg.sender != _borrower) revert NotBorrower();
  }

  function _requireTroveIsActive(ITroveManager _troveManager, address _borrower) internal view {
    uint status = _troveManager.getTroveStatus(_borrower);
    if (status != 1) revert TroveClosedOrNotExist();
  }

  function _requireNotInRecoveryMode(bool _isInRecoveryMode) internal pure {
    if (_isInRecoveryMode) revert NotAllowedInRecoveryMode();
  }

  function _requireTroveIsNotActive(ITroveManager _troveManager, address _borrower) internal view {
    uint status = _troveManager.getTroveStatus(_borrower);
    if (status == 1) revert ActiveTrove();
  }

  function _requireSufficientDebtBalance(IDebtToken _debtToken, address _borrower, uint _debtRepayment) internal view {
    if (_debtToken.balanceOf(_borrower) < _debtRepayment) revert InsufficientDebtToRepay();
  }

  // adds stableCoin debt including gas compensation if not already included
  function _getDebtTokenAmounts(
    ITokenManager _dTokenManager,
    TokenAmount[] memory _debts
  ) internal view returns (DebtTokenAmount[] memory debtTokenAmounts, DebtTokenAmount memory stableCoinEntry) {
    address stableCoinAddress = address(_dTokenManager.getStableCoin());

    bool stableCoinIncluded = false;
    for (uint i = 0; i < _debts.length; i++) {
      if (_debts[i].tokenAddress != stableCoinAddress) continue;

      stableCoinIncluded = true;
      break;
    }

    if (stableCoinIncluded) debtTokenAmounts = new DebtTokenAmount[](_debts.length);
    else debtTokenAmounts = new DebtTokenAmount[](_debts.length + 1);

    for (uint i = 0; i < _debts.length; i++) {
      IDebtToken debtToken = _dTokenManager.getDebtToken(_debts[i].tokenAddress);
      debtTokenAmounts[i] = DebtTokenAmount(debtToken, _debts[i].amount, 0);

      if (stableCoinIncluded && debtToken.isStableCoin()) stableCoinEntry = debtTokenAmounts[i];
    }

    if (!stableCoinIncluded) {
      IDebtToken debtToken = _dTokenManager.getStableCoin();
      debtTokenAmounts[_debts.length] = DebtTokenAmount(debtToken, 0, 0);
      stableCoinEntry = debtTokenAmounts[_debts.length];
    }

    return (debtTokenAmounts, stableCoinEntry);
  }

  function _requireNonZeroDebtChange(uint _change) internal pure {
    if (_change == 0) revert ZeroDebtChange();
  }

  function _requireValidAdjustmentInCurrentMode(
    bool _isCollWithdrawal,
    bool _isDebtIncrease,
    LocalVariables_adjustTrove memory _vars
  ) internal pure {
    /*
     *In Recovery Mode, only allow:
     *
     * - Pure collateral top-up
     * - Pure debt repayment
     * - Collateral top-up with debt repayment
     * - A debt increase combined with a collateral top-up which makes the ICR >= 150% and improves the ICR (and by extension improves the TCR).
     *
     * In Normal Mode, ensure:
     *
     * - The new ICR is above MCR
     * - The adjustment won't pull the TCR below CCR
     */
    if (_vars.isInRecoveryMode) {
      // BorrowerOps: Collateral withdrawal not permitted Recovery Mode
      if (_isCollWithdrawal) revert CollWithdrawPermittedInRM();
      if (_isDebtIncrease) _requireICRisAboveCCR(_vars.newICR);
    } else {
      // if Normal Mode

      _requireICRisAboveMCR(_vars.newICR);

      uint collChange = _vars.newCompositeCollInUSD > _vars.oldCompositeCollInUSD
        ? _vars.newCompositeCollInUSD - _vars.oldCompositeCollInUSD
        : _vars.oldCompositeCollInUSD - _vars.newCompositeCollInUSD;
      uint debtChange = _vars.newCompositeDebtInUSD > _vars.oldCompositeDebtInUSD
        ? _vars.newCompositeDebtInUSD - _vars.oldCompositeDebtInUSD
        : _vars.oldCompositeDebtInUSD - _vars.newCompositeDebtInUSD;
      uint newTCR = _getNewTCRFromTroveChange(
        collChange,
        !_isCollWithdrawal,
        debtChange,
        _isDebtIncrease,
        _vars.entireSystemColl,
        _vars.entireSystemDebt
      );
      _requireNewTCRisAboveCCR(newTCR);
    }
  }

  function _requireICRisAboveMCR(uint _newICR) internal pure {
    // BorrowerOps: An operation that would result in ICR < MCR is not permitted
    if (_newICR < MCR) revert ICR_lt_MCR();
  }

  function _requireICRisAboveCCR(uint _newICR) internal pure {
    // BorrowerOps: Operation must leave trove with ICR >= CCR
    if (_newICR < CCR) revert ICR_lt_CCR();
  }

  function _requireNewICRisAboveOldICR(uint _newICR, uint _oldICR) internal pure {
    // BorrowerOps: Cannot decrease your Trove's ICR in Recovery Mode
    if (_newICR < _oldICR) revert ICRDecreasedInRM();
  }

  function _requireNewTCRisAboveCCR(uint _newTCR) internal pure {
    // BorrowerOps: An operation that would result in TCR < CCR is not permitted
    if (_newTCR < CCR) revert TCR_lt_CCR();
  }

  function _requireAtLeastMinNetDebt(uint _netDebt, uint _repayment) internal pure {
    if (_netDebt < _repayment) revert Repaid_gt_CurrentDebt();
  }

  function _requireValidStableCoinRepayment(uint _currentDebt, uint _debtRepayment) internal pure {
    // BorrowerOps: Amount repaid must not be larger than the Trove's debt
    if (_debtRepayment > (_currentDebt - STABLE_COIN_GAS_COMPENSATION)) revert Repaid_gt_CurrentDebt();
  }

  function _requireValidMaxFeePercentage(uint _maxFeePercentage, bool _isInRecoveryMode) internal pure {
    if (_isInRecoveryMode) {
      if (_maxFeePercentage > MAX_BORROWING_FEE) revert MaxFee_gt_100_InRM();
    } else {
      if (_maxFeePercentage < BORROWING_FEE_FLOOR || _maxFeePercentage > MAX_BORROWING_FEE) revert MaxFee_out_Range();
    }
  }

  // --- ICR and TCR getters ---

  // Returns the composite debt (drawn debt + gas compensation) of a trove, for the purpose of ICR calculation
  function _getCompositeDebt(
    IPriceFeed _priceFeed,
    PriceCache memory _priceCache,
    DebtTokenAmount[] memory _debts
  ) internal view returns (uint debtInUSD) {
    for (uint i = 0; i < _debts.length; i++)
      debtInUSD += _priceFeed.getUSDValue(_priceCache, address(_debts[i].debtToken), _debts[i].netDebt);
  }

  function _getCompositeColl(
    IPriceFeed _priceFeed,
    PriceCache memory _priceCache,
    TokenAmount[] memory _colls
  ) internal view returns (uint collInUSD) {
    for (uint i = 0; i < _colls.length; i++)
      collInUSD += _priceFeed.getUSDValue(_priceCache, _colls[i].tokenAddress, _colls[i].amount);
  }
}
