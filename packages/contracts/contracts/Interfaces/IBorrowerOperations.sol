// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import './IBBase.sol';

// Common interface for the Trove Manager.
interface IBorrowerOperations is IBBase {
  // --- Events ---

  event BorrowerOperationsInitialized(
    address _troveManagerAddress,
    address _storagePoolAddress,
    address _stabilityPoolAddress,
    address _reservePoolAddress,
    address _priceFeedAddress,
    address _tokenManagerAddress,
    address _swapOperationsAddress,
    address _sortedTrovesAddress,
    address _collSurplusPoolAddress
  );
  event TroveCreated(address _borrower, TokenAmount[] _colls);
  event PaidBorrowingFee(address indexed _borrower, uint amount);

  // --- Custom Errors ---

  error NotFromStabilityPool();
  error NotFromSwapOps();
  error CollWithdrawPermittedInRM();
  error ICR_lt_MCR();
  error ICR_lt_CCR();
  error TCR_lt_CCR();
  error ICRDecreasedInRM();
  error MaxFee_gt_100_InRM();
  error MaxFee_out_Range();
  error Repaid_gt_CurrentDebt();
  error TroveClosedOrNotExist();
  error ActiveTrove();
  error NotAllowedInRecoveryMode();
  error NotBorrower();
  error WithdrawAmount_gt_Coll();
  error ZeroDebtChange();
  error InsufficientDebtToRepay();
  error ZeroDebtRepay();
  error UntrustedOraclesMintingIsFrozen(address token);

  // --- Functions ---

  function openTrove(TokenAmount[] memory _colls) external;

  function openTroveWithPermit(
    TokenAmount[] memory _colls,
    uint deadline,
    uint8[] memory v,
    bytes32[] memory r,
    bytes32[] memory s
  ) external;

  function addColl(TokenAmount[] memory _colls, address _upperHint, address _lowerHint) external;

  function addCollWithPermit(
    TokenAmount[] memory _colls,
    uint deadline,
    uint8[] memory v,
    bytes32[] memory r,
    bytes32[] memory s,
    address _upperHint,
    address _lowerHint
  ) external;

  function withdrawColl(TokenAmount[] memory _colls, address _upperHint, address _lowerHint) external;

  function increaseDebt(address _borrower, address _to, TokenAmount[] memory _debts, MintMeta memory _meta) external;

  function repayDebt(TokenAmount[] memory _debts, address _upperHint, address _lowerHint) external;

  function repayDebtFromPoolBurn(
    address borrower,
    TokenAmount[] memory _debts,
    address _upperHint,
    address _lowerHint
  ) external;

  function closeTrove() external;

  function claimCollateral() external;
}
