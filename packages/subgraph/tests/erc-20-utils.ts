import { Address, BigInt, ethereum } from '@graphprotocol/graph-ts';
import { newMockEvent } from 'matchstick-as';
import { Approval, Transfer } from '../generated/templates/ERC20Template/ERC20';

export function createApprovalEvent(owner: Address, spender: Address, value: BigInt): Approval {
  let approvalEvent = changetype<Approval>(newMockEvent());

  approvalEvent.parameters = new Array();

  approvalEvent.parameters.push(new ethereum.EventParam('owner', ethereum.Value.fromAddress(owner)));
  approvalEvent.parameters.push(new ethereum.EventParam('spender', ethereum.Value.fromAddress(spender)));
  approvalEvent.parameters.push(new ethereum.EventParam('value', ethereum.Value.fromSignedBigInt(value)));

  return approvalEvent;
}

export function createTransferEvent(from: Address, to: Address, value: BigInt): Transfer {
  let transferEvent = changetype<Transfer>(newMockEvent());

  transferEvent.parameters = new Array();

  transferEvent.parameters.push(new ethereum.EventParam('from', ethereum.Value.fromAddress(from)));
  transferEvent.parameters.push(new ethereum.EventParam('to', ethereum.Value.fromAddress(to)));
  transferEvent.parameters.push(new ethereum.EventParam('value', ethereum.Value.fromSignedBigInt(value)));

  return transferEvent;
}
