import { Address, BigInt, ethereum } from '@graphprotocol/graph-ts';
import { PriceFeed } from '../../generated/PriceFeed/PriceFeed';
import { SystemInfo, TokenCandle, TokenCandleSingleton } from '../../generated/schema';
import { DebtToken } from '../../generated/templates/DebtTokenTemplate/DebtToken';
import { ERC20 } from '../../generated/templates/ERC20Template/ERC20';
import { SwapPair } from '../../generated/templates/SwapPairTemplate/SwapPair';

// 1min, 10min, 1hour, 6hour, 1day, 1week
const CandleSizes = [1, 10, 60, 360, 1440, 10080];
export const oneEther = BigInt.fromI64(1000000000000000000);

/**
 * Cant convert a float64 to a BigInt so have to do a workaround
 *
 * @param n numbers of zeros
 * @returns A Bigint with 10^n
 */
function bigIntWithZeros(n: i32): BigInt {
  const str = '1' + '0'.repeat(n);
  return BigInt.fromString(str);
}

/**
 * Initializes the Singleton once for a new Token
 */
export function handleCreateTokenCandleSingleton(event: ethereum.Event, tokenAddress: Address): void {
  let candleSingleton: TokenCandleSingleton | null;

  const systemInfo = SystemInfo.load(`SystemInfo`)!;
  const priceFeedContract = PriceFeed.bind(Address.fromBytes(systemInfo.priceFeed));

  const tokenPrice = priceFeedContract.getPrice(tokenAddress).getPrice();

  for (let i = 0; i < CandleSizes.length; i++) {
    candleSingleton = TokenCandleSingleton.load(
      `TokenCandleSingleton-${tokenAddress.toHexString()}-${CandleSizes[i].toString()}`,
    );

    if (!candleSingleton) {
      candleSingleton = new TokenCandleSingleton(
        `TokenCandleSingleton-${tokenAddress.toHexString()}-${CandleSizes[i].toString()}`,
      );

      candleSingleton.token = tokenAddress;
      candleSingleton.candleSize = CandleSizes[i];
      candleSingleton.timestamp = event.block.timestamp;
      candleSingleton.open = tokenPrice;
      candleSingleton.high = tokenPrice;
      candleSingleton.low = tokenPrice;
      candleSingleton.close = tokenPrice;
      candleSingleton.volume = BigInt.fromI32(0);

      candleSingleton.save();
    }
  }
}

/**
 * Updates the Singleton and creates new Candles if candle is closed
 */
export function handleUpdateTokenCandle_low_high(
  event: ethereum.Event,
  swapPair: Address,
  pairPositionStable: number,
  pairToken: Address,
): void {
  // calculate price from ratio to stable and oraclePrice
  const systemInfo = SystemInfo.load(`SystemInfo`)!;
  const priceFeedContract = PriceFeed.bind(Address.fromBytes(systemInfo.priceFeed));
  const stablePrice = priceFeedContract.getPrice(Address.fromBytes(systemInfo.stableCoin)).getPrice();

  let pairTokenDecimals = oneEther;
  const try_pairTokenDecimals = DebtToken.bind(pairToken).try_decimals();
  if (try_pairTokenDecimals.reverted) {
    pairTokenDecimals = bigIntWithZeros(ERC20.bind(pairToken).try_decimals().value);
  } else {
    pairTokenDecimals = bigIntWithZeros(try_pairTokenDecimals.value);
  }

  const swapPairReserves = SwapPair.bind(swapPair).getReserves();
  const tokenPriceInStable =
    pairPositionStable === 0
      ? swapPairReserves.get_reserve0().times(pairTokenDecimals).div(swapPairReserves.get_reserve1())
      : swapPairReserves.get_reserve1().times(pairTokenDecimals).div(swapPairReserves.get_reserve0());
  const tokenPriceUSD = tokenPriceInStable.times(stablePrice).div(oneEther);

  for (let i = 0; i < CandleSizes.length; i++) {
    const candleSingleton = TokenCandleSingleton.load(
      `TokenCandleSingleton-${pairToken.toHexString()}-${CandleSizes[i].toString()}`,
    )!;

    if (candleSingleton.timestamp.plus(BigInt.fromI32(CandleSizes[i] * 60)) < event.block.timestamp) {
      handleCloseCandle(event, pairToken, CandleSizes[i], tokenPriceUSD);
    } else {
      if (candleSingleton.low.gt(tokenPriceUSD)) {
        candleSingleton.low = tokenPriceUSD;
      } else if (candleSingleton.high.lt(tokenPriceUSD)) {
        candleSingleton.high = tokenPriceUSD;
      }

      candleSingleton.save();
    }
  }
}

/**
 * Updates the Singleton and creates new Candles if candle is closed
 */
export function handleUpdateTokenCandle_volume(
  event: ethereum.Event,
  swapPair: Address,
  pairPositionStable: number,
  pairToken: Address,
  additionalTradeVolume: BigInt,
): void {
  // calculate price from ratio to stable and oraclePrice
  const systemInfo = SystemInfo.load(`SystemInfo`)!;
  const priceFeedContract = PriceFeed.bind(Address.fromBytes(systemInfo.priceFeed));
  const stablePrice = priceFeedContract.getPrice(Address.fromBytes(systemInfo.stableCoin)).getPrice();

  const swapPairReserves = SwapPair.bind(swapPair).getReserves();
  const tokenPriceInStable =
    pairPositionStable === 0
      ? swapPairReserves.get_reserve0().times(oneEther).div(swapPairReserves.get_reserve1())
      : swapPairReserves.get_reserve1().times(oneEther).div(swapPairReserves.get_reserve0());
  const tokenPriceUSD = tokenPriceInStable.times(stablePrice).div(oneEther);

  for (let i = 0; i < CandleSizes.length; i++) {
    const candleSingleton = TokenCandleSingleton.load(
      `TokenCandleSingleton-${pairToken.toHexString()}-${CandleSizes[i].toString()}`,
    )!;

    if (candleSingleton.timestamp.plus(BigInt.fromI32(CandleSizes[i] * 60)) < event.block.timestamp) {
      handleCloseCandle(event, pairToken, CandleSizes[i], tokenPriceUSD, additionalTradeVolume);
    } else {
      candleSingleton.volume = candleSingleton.volume.plus(additionalTradeVolume);
      candleSingleton.save();
    }
  }
}

function handleCloseCandle(
  event: ethereum.Event,
  pairToken: Address,
  candleSize: i32,
  tokenPriceUSD: BigInt,
  initialTradeVolume: BigInt = BigInt.fromI32(0),
): void {
  const candleSingleton = TokenCandleSingleton.load(
    `TokenCandleSingleton-${pairToken.toHexString()}-${candleSize.toString()}`,
  )!;

  // Save away new closed candle
  const newClosedCandle = new TokenCandle(event.transaction.hash.concatI32(event.logIndex.toI32()));
  newClosedCandle.token = pairToken;
  newClosedCandle.candleSize = candleSize;
  newClosedCandle.timestamp = candleSingleton.timestamp;
  newClosedCandle.open = candleSingleton.open;
  newClosedCandle.high = candleSingleton.high;
  newClosedCandle.low = candleSingleton.low;
  newClosedCandle.close = tokenPriceUSD;
  newClosedCandle.volume = candleSingleton.volume;
  newClosedCandle.save();

  // Prepare new candle to be populated
  candleSingleton.timestamp = event.block.timestamp;
  candleSingleton.open = tokenPriceUSD;
  candleSingleton.high = tokenPriceUSD;
  candleSingleton.low = tokenPriceUSD;
  candleSingleton.close = BigInt.fromI32(0);
  candleSingleton.volume = initialTradeVolume;

  candleSingleton.save();
}
