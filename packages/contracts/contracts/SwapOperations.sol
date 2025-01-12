// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import './SwapPair.sol';
import './Dependencies/LiquityBase.sol';
import './Interfaces/ISwapOperations.sol';
import './Interfaces/IBorrowerOperations.sol';
import './Interfaces/ITokenManager.sol';
import './Dependencies/CheckContract.sol';
import './Interfaces/IPriceFeed.sol';
import './Interfaces/ITroveManager.sol';

contract SwapOperations is ISwapOperations, Ownable(msg.sender), CheckContract, LiquityBase {
  // --- Connected contract declarations ---

  ITroveManager public troveManager;
  IBorrowerOperations public borrowerOperations;
  IPriceFeed public priceFeed;
  ITokenManager public tokenManager;

  // --- Data structures ---

  mapping(address => mapping(address => address)) public getPair;
  mapping(address => bool) public isPair;
  address[] public allPairs;

  // --- Dependency setters ---

  function setAddresses(
    address _borrowerOperationsAddress,
    address _troveManagerAddress,
    address _priceFeedAddress,
    address _tokenManager
  ) external onlyOwner {
    checkContract(_borrowerOperationsAddress);
    checkContract(_troveManagerAddress);
    checkContract(_priceFeedAddress);
    checkContract(_tokenManager);

    borrowerOperations = IBorrowerOperations(_borrowerOperationsAddress);
    troveManager = ITroveManager(_troveManagerAddress);
    priceFeed = IPriceFeed(_priceFeedAddress);
    tokenManager = ITokenManager(_tokenManager);

    emit SwapOperationsInitialized(_borrowerOperationsAddress, _troveManagerAddress, _priceFeedAddress, _tokenManager);
  }

  modifier ensure(uint deadline) {
    if (deadline < block.timestamp) revert Expired();
    _;
  }

  // --- Pair Management ---

  function allPairsLength() external view returns (uint) {
    return allPairs.length;
  }

  function createPair(address tokenA, address tokenB) external onlyOwner returns (address pair) {
    if (tokenA == tokenB) revert IdenticalAddresses();
    if (tokenA != address(tokenManager.getStableCoin()) && tokenB != address(tokenManager.getStableCoin()))
      revert PairRequiresStable();

    (address token0, address token1) = sortTokens(tokenA, tokenB);
    if (token0 == address(0)) revert ZeroAddress();
    if (getPair[token0][token1] != address(0)) revert PairExists(); // single check is sufficient

    bytes memory bytecode = type(SwapPair).creationCode;
    bytes32 salt = keccak256(abi.encodePacked(token0, token1));
    assembly {
      pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
    }

    ISwapPair(pair).initialize(token0, token1, address(tokenManager), address(priceFeed));
    getPair[token0][token1] = pair;
    getPair[token1][token0] = pair; // populate mapping in the reverse direction
    allPairs.push(pair);
    isPair[pair] = true;

    emit PairCreated(token0, token1, pair, allPairs.length);
  }

  // --- Getter functions ---

  function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
    if (amountA == 0) revert InsufficientAmount();
    if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();

    amountB = (amountA * reserveB) / reserveA;
  }

  function getAmountOut(
    uint amountIn,
    uint reserveIn,
    uint reserveOut,
    uint32 swapFee
  ) public pure virtual override returns (uint amountOut) {
    if (amountIn == 0) revert InsufficientInputAmount();
    if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

    uint amountInWithFee = amountIn * (SWAP_FEE_PRECISION - swapFee);
    uint numerator = amountInWithFee * reserveOut;
    uint denominator = reserveIn * SWAP_FEE_PRECISION + amountInWithFee;
    amountOut = numerator / denominator;
  }

  function getAmountIn(
    uint amountOut,
    uint reserveIn,
    uint reserveOut,
    uint32 swapFee
  ) public pure virtual override returns (uint amountIn) {
    if (amountOut == 0) revert InsufficientOutputAmount();
    if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

    uint numerator = reserveIn * amountOut * SWAP_FEE_PRECISION;
    uint denominator = (reserveOut - amountOut) * (SWAP_FEE_PRECISION - swapFee);
    amountIn = (numerator / denominator) + 1;
  }

  function getAmountsOut(
    uint amountIn,
    address[] memory path
  ) public view virtual override returns (uint[] memory amounts) {
    if (path.length < 2) revert InvalidPath();

    amounts = new uint[](path.length);
    amounts[0] = amountIn;
    for (uint i; i < path.length - 1; i++) {
      (uint reserveIn, uint reserveOut, uint32 swapFee) = getReserves(path[i], path[i + 1]);
      amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut, swapFee);
    }
  }

  function getAmountsIn(
    uint amountOut,
    address[] memory path
  ) public view virtual override returns (uint[] memory amounts) {
    if (path.length < 2) revert InvalidPath();

    amounts = new uint[](path.length);
    amounts[amounts.length - 1] = amountOut;
    for (uint i = path.length - 1; i > 0; i--) {
      (uint reserveIn, uint reserveOut, uint32 swapFee) = getReserves(path[i - 1], path[i]);
      amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut, swapFee);
    }
  }

  // --- Liquidity functions ---

  struct ProvidingVars {
    address pair;
    uint senderBalanceA;
    uint senderBalanceB;
    uint fromBalanceA;
    uint fromBalanceB;
    uint fromMintA;
    uint fromMintB;
  }

  function addLiquidity(
    address tokenA,
    address tokenB,
    uint amountADesired,
    uint amountBDesired,
    uint amountAMin,
    uint amountBMin,
    MintMeta memory _mintMeta,
    uint deadline
  ) public virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
    ProvidingVars memory vars;
    vars.pair = getPair[tokenA][tokenB];
    if (vars.pair == address(0)) revert PairDoesNotExist();

    {
      (uint reserveA, uint reserveB, ) = getReserves(tokenA, tokenB);
      if (reserveA == 0 && reserveB == 0) {
        (amountA, amountB) = (amountADesired, amountBDesired);
      } else {
        uint amountBOptimal = quote(amountADesired, reserveA, reserveB);
        if (amountBOptimal <= amountBDesired) {
          if (amountBOptimal < amountBMin) revert InsufficientBAmount();
          (amountA, amountB) = (amountADesired, amountBOptimal);
        } else {
          uint amountAOptimal = quote(amountBDesired, reserveB, reserveA);
          assert(amountAOptimal <= amountADesired);
          if (amountAOptimal < amountAMin) revert InsufficientAAmount();
          (amountA, amountB) = (amountAOptimal, amountBDesired);
        }
      }
    }

    vars.senderBalanceA = IERC20(tokenA).balanceOf(msg.sender);
    vars.senderBalanceB = IERC20(tokenB).balanceOf(msg.sender);

    vars.fromBalanceA = LiquityMath._min(vars.senderBalanceA, amountA);
    vars.fromBalanceB = LiquityMath._min(vars.senderBalanceB, amountB);

    vars.fromMintA = amountA - vars.fromBalanceA;
    vars.fromMintB = amountB - vars.fromBalanceB;

    // mint new tokens if the sender did not have enough
    if (vars.fromMintA != 0 || vars.fromMintB != 0) {
      TokenAmount[] memory debtsToMint;
      if (vars.fromMintA != 0 && vars.fromMintB != 0) {
        // mint both
        debtsToMint = new TokenAmount[](2);
        debtsToMint[0] = TokenAmount(tokenA, vars.fromMintA);
        debtsToMint[1] = TokenAmount(tokenB, vars.fromMintB);
      } else {
        // mint only 1 token
        debtsToMint = new TokenAmount[](1);
        debtsToMint[0] = (
          vars.fromMintA != 0
            ? TokenAmount(tokenA, vars.fromMintA) // mint A
            : TokenAmount(tokenB, vars.fromMintB) // mint B
        );
      }
      borrowerOperations.increaseDebt(msg.sender, vars.pair, debtsToMint, _mintMeta);
    }

    // transfer tokens sourced from senders balance
    if (vars.fromBalanceA != 0) safeTransferFrom(tokenA, msg.sender, vars.pair, vars.fromBalanceA);
    if (vars.fromBalanceB != 0) safeTransferFrom(tokenB, msg.sender, vars.pair, vars.fromBalanceB);

    liquidity = ISwapPair(vars.pair).mint(msg.sender);
  }

  function addLiquidityWithPermit(
    address tokenA,
    address tokenB,
    uint amountADesired,
    uint amountBDesired,
    uint amountAMin,
    uint amountBMin,
    MintMeta memory _mintMeta,
    uint deadline,
    uint8[] memory v,
    bytes32[] memory r,
    bytes32[] memory s
  ) external returns (uint amountA, uint amountB, uint liquidity) {
    IERC20Permit(tokenA).permit(msg.sender, address(this), amountADesired, deadline, v[0], r[0], s[0]);
    IERC20Permit(tokenB).permit(msg.sender, address(this), amountBDesired, deadline, v[1], r[1], s[1]);
    return addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, _mintMeta, deadline);
  }

  struct RemovalVars {
    address token0;
    address token1;
    uint amount0;
    uint amount1;
    uint burned0;
    uint burned1;
  }

  function removeLiquidity(
    address tokenA,
    address tokenB,
    uint liquidity,
    uint amountAMin,
    uint amountBMin,
    address _upperHint,
    address _lowerHint,
    uint deadline
  ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
    RemovalVars memory vars;
    (vars.token0, vars.token1) = sortTokens(tokenA, tokenB);

    // receive tokens from pair
    address pair = getPair[tokenA][tokenB];
    PriceCache memory priceCache = priceFeed.buildPriceCache();
    (vars.amount0, vars.amount1, vars.burned0, vars.burned1) = ISwapPair(pair).burn(
      msg.sender,
      liquidity,
      // check if there are some debts which has to be repaid first
      troveManager.getTroveRepayableDebt(priceCache, msg.sender, vars.token0, false),
      troveManager.getTroveRepayableDebt(priceCache, msg.sender, vars.token1, false)
    );

    // handle trove debt repayment
    if (vars.burned0 != 0 || vars.burned1 != 0) {
      TokenAmount[] memory debtsToRepay;
      if (vars.burned0 != 0 && vars.burned1 != 0) {
        // repay both
        debtsToRepay = new TokenAmount[](2);
        debtsToRepay[0] = TokenAmount(vars.token0, vars.burned0);
        debtsToRepay[1] = TokenAmount(vars.token1, vars.burned1);
      } else {
        // repay only 1 token
        debtsToRepay = new TokenAmount[](1);
        debtsToRepay[0] = (
          vars.burned0 != 0 ? TokenAmount(vars.token0, vars.burned0) : TokenAmount(vars.token1, vars.burned1)
        );
      }
      borrowerOperations.repayDebtFromPoolBurn(msg.sender, debtsToRepay, _upperHint, _lowerHint);
    }

    (amountA, amountB) = tokenA == vars.token0 ? (vars.amount0, vars.amount1) : (vars.amount1, vars.amount0);
    if (amountA < amountAMin) revert InsufficientAAmount();
    if (amountB < amountBMin) revert InsufficientBAmount();
  }

  // **** SWAP ****
  // requires the initial amount to have already been sent to the first pair
  // --- Swap functions ---

  // requires the initial amount to have already been sent to the first pair
  function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
    for (uint i; i < path.length - 1; i++) {
      (address input, address output) = (path[i], path[i + 1]);
      (address token0, ) = sortTokens(input, output);

      uint amountOut = amounts[i + 1];
      (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));

      address to = i < path.length - 2 ? getPair[output][path[i + 2]] : _to;
      ISwapPair(getPair[input][output]).swap(amount0Out, amount1Out, to);
    }
  }

  function swapExactTokensForTokens(
    uint amountIn,
    uint amountOutMin,
    address[] calldata path,
    address to,
    uint deadline
  ) public virtual override ensure(deadline) returns (uint[] memory amounts) {
    amounts = getAmountsOut(amountIn, path);
    if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();
    safeTransferFrom(path[0], msg.sender, getPair[path[0]][path[1]], amounts[0]);
    _swap(amounts, path, to);
  }

  function swapTokensForExactTokens(
    uint amountOut,
    uint amountInMax,
    address[] calldata path,
    address to,
    uint deadline
  ) public virtual override ensure(deadline) returns (uint[] memory amounts) {
    amounts = getAmountsIn(amountOut, path);
    if (amounts[0] > amountInMax) revert ExcessiveInputAmount();
    safeTransferFrom(path[0], msg.sender, getPair[path[0]][path[1]], amounts[0]);
    _swap(amounts, path, to);
  }

  function swapExactTokensForTokensWithPermit(
    uint amountIn,
    uint amountOutMin,
    address[] calldata path,
    address to,
    uint deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external returns (uint[] memory amounts) {
    IERC20Permit(path[0]).permit(msg.sender, address(this), amountIn, deadline, v, r, s);
    return swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
  }

  // --- Position functions ---

  function openLongPosition(
    uint stableToMintIn,
    uint debtOutMin,
    address debtTokenAddress,
    address to,
    MintMeta memory _mintMeta,
    uint deadline
  ) external override ensure(deadline) returns (uint[] memory amounts) {
    address[] memory path = new address[](2);
    path[0] = address(tokenManager.getStableCoin());
    path[1] = debtTokenAddress;

    return _openPosition(stableToMintIn, debtOutMin, path, to, _mintMeta);
  }

  function openShortPosition(
    uint debtToMintIn,
    uint stableOutMin,
    address debtTokenAddress,
    address to,
    MintMeta memory _mintMeta,
    uint deadline
  ) external override ensure(deadline) returns (uint[] memory amounts) {
    address[] memory path = new address[](2);
    path[0] = debtTokenAddress;
    path[1] = address(tokenManager.getStableCoin());

    return _openPosition(debtToMintIn, stableOutMin, path, to, _mintMeta);
  }

  function _openPosition(
    uint amountIn,
    uint amountOutMin,
    address[] memory path,
    address to,
    MintMeta memory _mintMeta
  ) internal returns (uint[] memory amounts) {
    address pair = getPair[path[0]][path[1]];
    if (pair == address(0)) revert PairDoesNotExist();

    amounts = getAmountsOut(amountIn, path);
    if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();

    tokenManager.getDebtToken(path[0]); //check if debt token

    // mint the debt token and transfer it to the pair
    TokenAmount[] memory debtsToMint = new TokenAmount[](1);
    debtsToMint[0] = TokenAmount(path[0], amounts[0]);
    borrowerOperations.increaseDebt(msg.sender, pair, debtsToMint, _mintMeta);

    // execute the swap
    _swap(amounts, path, to);

    return amounts;
  }

  // --- Helper functions ---

  function getReserves(
    address tokenA,
    address tokenB
  ) internal view returns (uint reserveA, uint reserveB, uint32 swapFee) {
    address pairAddress = getPair[tokenA][tokenB];
    if (pairAddress == address(0)) revert PairDoesNotExist();

    ISwapPair pair = ISwapPair(pairAddress);
    swapFee = pair.getSwapFee();

    (uint reserve0, uint reserve1, ) = pair.getReserves();
    (address token0, ) = sortTokens(tokenA, tokenB);
    (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
  }

  function sortTokens(address tokenA, address tokenB) internal view returns (address token0, address token1) {
    if (tokenA == tokenB) revert IdenticalAddresses();
    if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();

    address stableCoin = address(tokenManager.getStableCoin());
    if (tokenA == stableCoin) return (tokenA, tokenB);
    if (tokenB == stableCoin) return (tokenB, tokenA);
    return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
  }

  function safeTransferFrom(address token, address from, address to, uint256 value) internal {
    // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
    (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
    if (!success || (data.length > 0 && abi.decode(data, (bool)) == false)) revert TransferFromFailed();
  }
}
