import { Address, BigInt, ethereum } from '@graphprotocol/graph-ts';
import { newMockEvent } from 'matchstick-as';
import { Approval, Burn, Mint, Swap, Sync, Transfer } from '../generated/templates/SwapPairTemplate/SwapPair';

export function createApprovalEvent(owner: Address, spender: Address, value: BigInt): Approval {
  let approvalEvent = changetype<Approval>(newMockEvent());

  approvalEvent.parameters = new Array();

  approvalEvent.parameters.push(new ethereum.EventParam('owner', ethereum.Value.fromAddress(owner)));
  approvalEvent.parameters.push(new ethereum.EventParam('spender', ethereum.Value.fromAddress(spender)));
  approvalEvent.parameters.push(new ethereum.EventParam('value', ethereum.Value.fromSignedBigInt(value)));

  return approvalEvent;
}

export function createBurnEvent(sender: Address, amount0: BigInt, amount1: BigInt, to: Address): Burn {
  let burnEvent = changetype<Burn>(newMockEvent());

  burnEvent.parameters = new Array();

  burnEvent.parameters.push(new ethereum.EventParam('sender', ethereum.Value.fromAddress(sender)));
  burnEvent.parameters.push(new ethereum.EventParam('amount0', ethereum.Value.fromSignedBigInt(amount0)));
  burnEvent.parameters.push(new ethereum.EventParam('amount1', ethereum.Value.fromSignedBigInt(amount1)));
  burnEvent.parameters.push(new ethereum.EventParam('to', ethereum.Value.fromAddress(to)));

  return burnEvent;
}

export function createMintEvent(sender: Address, amount0: BigInt, amount1: BigInt): Mint {
  let mintEvent = changetype<Mint>(newMockEvent());

  mintEvent.parameters = new Array();

  mintEvent.parameters.push(new ethereum.EventParam('sender', ethereum.Value.fromAddress(sender)));
  mintEvent.parameters.push(new ethereum.EventParam('amount0', ethereum.Value.fromSignedBigInt(amount0)));
  mintEvent.parameters.push(new ethereum.EventParam('amount1', ethereum.Value.fromSignedBigInt(amount1)));

  return mintEvent;
}

export function createSwapEvent(
  sender: Address,
  amount0In: BigInt,
  amount1In: BigInt,
  amount0Out: BigInt,
  amount1Out: BigInt,
  currentSwapFee: BigInt,
  to: Address,
): Swap {
  let swapEvent = changetype<Swap>(newMockEvent());

  swapEvent.parameters = new Array();

  swapEvent.parameters.push(new ethereum.EventParam('sender', ethereum.Value.fromAddress(sender)));
  swapEvent.parameters.push(new ethereum.EventParam('amount0In', ethereum.Value.fromSignedBigInt(amount0In)));
  swapEvent.parameters.push(new ethereum.EventParam('amount1In', ethereum.Value.fromSignedBigInt(amount1In)));
  swapEvent.parameters.push(new ethereum.EventParam('amount0Out', ethereum.Value.fromSignedBigInt(amount0Out)));
  swapEvent.parameters.push(new ethereum.EventParam('amount1Out', ethereum.Value.fromSignedBigInt(amount1Out)));
  swapEvent.parameters.push(new ethereum.EventParam('currentSwapFee', ethereum.Value.fromSignedBigInt(currentSwapFee)));
  swapEvent.parameters.push(new ethereum.EventParam('to', ethereum.Value.fromAddress(to)));

  return swapEvent;
}

export function createSyncEvent(reserve0: BigInt, reserve1: BigInt): Sync {
  let syncEvent = changetype<Sync>(newMockEvent());

  syncEvent.parameters = new Array();

  syncEvent.parameters.push(new ethereum.EventParam('reserve0', ethereum.Value.fromSignedBigInt(reserve0)));
  syncEvent.parameters.push(new ethereum.EventParam('reserve1', ethereum.Value.fromSignedBigInt(reserve1)));

  return syncEvent;
}

export function createTransferEvent(from: Address, to: Address, value: BigInt): Transfer {
  let transferEvent = changetype<Transfer>(newMockEvent());

  transferEvent.parameters = new Array();

  transferEvent.parameters.push(new ethereum.EventParam('from', ethereum.Value.fromAddress(from)));
  transferEvent.parameters.push(new ethereum.EventParam('to', ethereum.Value.fromAddress(to)));
  transferEvent.parameters.push(new ethereum.EventParam('value', ethereum.Value.fromSignedBigInt(value)));

  return transferEvent;
}
