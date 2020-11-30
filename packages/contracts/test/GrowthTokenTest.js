const deploymentHelper = require("../utils/deploymentHelpers.js")
const testHelpers = require("../utils/testHelpers.js")

const { keccak256 } = require('@ethersproject/keccak256');
const { defaultAbiCoder } = require('@ethersproject/abi');
const { toUtf8Bytes } = require('@ethersproject/strings');
const { pack } = require('@ethersproject/solidity');
const { hexlify } = require("@ethersproject/bytes");
const { ecsign } = require('ethereumjs-util');

const sign = (digest, privateKey) => {
  return ecsign(Buffer.from(digest.slice(2), 'hex'), Buffer.from(privateKey.slice(2), 'hex'))
}

const PERMIT_TYPEHASH = keccak256(
  toUtf8Bytes('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)')
)

// Gets the EIP712 domain separator
const getDomainSeparator = (name, contractAddress, chainId, version)  => {
  return keccak256(defaultAbiCoder.encode(['bytes32', 'bytes32', 'bytes32', 'uint256', 'address'], 
  [ 
    keccak256(toUtf8Bytes('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
    keccak256(toUtf8Bytes(name)), 
    keccak256(toUtf8Bytes(version)),
    parseInt(chainId), contractAddress.toLowerCase()
  ]))
}

// Returns the EIP712 hash which should be signed by the user
// in order to make a call to `permit`
const getPermitDigest = ( name, address, chainId, version,
                          owner, spender, value , 
                          nonce, deadline ) => {

  const DOMAIN_SEPARATOR = getDomainSeparator(name, address, chainId, version)
  return keccak256(pack(['bytes1', 'bytes1', 'bytes32', 'bytes32'],
    ['0x19', '0x01', DOMAIN_SEPARATOR, 
      keccak256(defaultAbiCoder.encode(
        ['bytes32', 'address', 'address', 'uint256', 'uint256', 'uint256'],
        [PERMIT_TYPEHASH, owner, spender, value, nonce, deadline])),
    ]))
}

const th = testHelpers.TestHelper
const toBN = th.toBN
const dec = th.dec
const getDifference = th.getDifference
const timeValues = testHelpers.TimeValues

const ZERO_ADDRESS = th.ZERO_ADDRESS
const assertRevert = th.assertRevert

contract('LQTY Token', async accounts => {
  const [owner, A, B, C, D] = accounts

  // the second account our buidlerenv creates (for EOA A)
  // from https://github.com/liquity/dev/blob/main/packages/contracts/buidlerAccountsList2k.js#L3
  const A_PrivateKey = '0xeaa445c85f7b438dEd6e831d06a4eD0CEBDc2f8527f84Fcda6EBB5fCfAd4C0e9'


  let contracts
  let lqtyTokenTester
  let lqtyStaking
  let communityIssuance
  
  let tokenName
  let tokenVersion
  let chainId

  const mintToABC = async () => {
      // mint some tokens
      await lqtyTokenTester.unprotectedMint(A, dec(150, 18))
      await lqtyTokenTester.unprotectedMint(B, dec(100, 18))
      await lqtyTokenTester.unprotectedMint(C, dec(50, 18))
  }
beforeEach(async () => {
    contracts = await deploymentHelper.deployLiquityCore()
    const LQTYContracts = await deploymentHelper.deployLQTYTesterContractsBuidler()

    lqtyStaking = LQTYContracts.lqtyStaking
    lqtyTokenTester = LQTYContracts.lqtyToken
    communityIssuance = LQTYContracts.communityIssuance

    tokenName = await lqtyTokenTester.name()
    tokenVersion = await lqtyTokenTester.version()
    chainId = await web3.eth.getChainId()

    await deploymentHelper.connectLQTYContracts(LQTYContracts)
    await deploymentHelper.connectCoreContracts(contracts, LQTYContracts)
    await deploymentHelper.connectLQTYContractsToCore(LQTYContracts, contracts)
  })

  it('balanceOf(): gets the balance of the account', async () => {
    await mintToABC()

    const A_Balance = (await lqtyTokenTester.balanceOf(A))
    const B_Balance = (await lqtyTokenTester.balanceOf(B))
    const C_Balance = (await lqtyTokenTester.balanceOf(C))

    assert.equal(A_Balance, dec(150, 18))
    assert.equal(B_Balance, dec(100, 18))
    assert.equal(C_Balance, dec(50, 18))
  })

  it('totalSupply(): gets the total supply', async () => {
    const total = (await lqtyTokenTester.totalSupply()).toString()
    /* Total supply should be 100 million, with a rounding error of 1e-18, due to splitting the initial supply
    between CommunityIssuance and the Liquity admin address */
    assert.equal(getDifference(total,  dec(100, 24)), 1) 
  })

  it("name(): returns the token's name", async () => {
    const name = await lqtyTokenTester.name()
    assert.equal(name, "LQTY")
  })

  it("symbol(): returns the token's symbol", async () => {
    const symbol = await lqtyTokenTester.symbol()
    assert.equal(symbol, "LQTY")
  })

  it("version(): returns the token contract's version", async () => {
    const version = await lqtyTokenTester.version()
    assert.equal(version, "1")
  })

  it("decimal(): returns the number of decimal digits used", async () => {
    const decimals = await lqtyTokenTester.decimals()
    assert.equal(decimals, "18")
  })

  it("allowance(): returns an account's spending allowance for another account's balance", async () => {
    await mintToABC()

    await lqtyTokenTester.approve(A, dec(100, 18), {from: B})

    const allowance_A = await lqtyTokenTester.allowance(B, A)
    const allowance_D = await lqtyTokenTester.allowance(B, D)

    assert.equal(allowance_A, dec(100, 18))
    assert.equal(allowance_D, '0')
  })

  it("approve(): approves an account to spend the specified ammount", async () => {
    await mintToABC()

    const allowance_A_before = await lqtyTokenTester.allowance(B, A)
    assert.equal(allowance_A_before, '0')

    await lqtyTokenTester.approve(A, dec(100, 18), {from: B})

    const allowance_A_after = await lqtyTokenTester.allowance(B, A)
    assert.equal(allowance_A_after, dec(100, 18))

    // B attempts to approve more than his balance - check it reverts
    const txPromise = lqtyTokenTester.approve(C, dec(1000, 18), {from: B})
    assertRevert(txPromise)
  })

  it("approve(): reverts when spender param is address(0)", async () => {
    await mintToABC()

    const txPromise = lqtyTokenTester.approve(ZERO_ADDRESS, dec(100, 18), {from: B})
    assertRevert(txPromise)
  })

  it("approve(): reverts when owner param is address(0)", async () => {
    await mintToABC()

    const txPromise =  lqtyTokenTester.callInternalApprove(ZERO_ADDRESS, A, dec(100, 18), {from: B})
    assertRevert(txPromise)
  })

  it("transferFrom(): successfully transfers from an account which is it approved to transfer from", async () => {
    await mintToABC()

    const allowance_A_0 = await lqtyTokenTester.allowance(B, A)
    assert.equal(allowance_A_0, '0')

    await lqtyTokenTester.approve(A, dec(50, 18), {from: B})

    // Check A's allowance of B's funds has increased
    const allowance_A_1= await lqtyTokenTester.allowance(B, A)
    assert.equal(allowance_A_1, dec(50, 18))

    assert.equal(await lqtyTokenTester.balanceOf(C), dec(50, 18))

    // A transfers from B to C, using up her allowance
    await lqtyTokenTester.transferFrom(B, C, dec(50, 18), {from: A})
    assert.equal(await lqtyTokenTester.balanceOf(C), dec(100, 18))

     // Check A's allowance of B's funds has decreased
    const allowance_A_2= await lqtyTokenTester.allowance(B, A)
    assert.equal(allowance_A_2, '0')

    // Check B's balance has decreased
    assert.equal(await lqtyTokenTester.balanceOf(B), dec(50, 18))

    // A tries to transfer more tokens from B's account to C than she's allowed
    const txPromise = lqtyTokenTester.transferFrom(B, C, dec(50, 18), {from: A})
    assertRevert(txPromise)
  })

  it("transfer(): increases the recipient's balance by the correct amount", async () => {
    await mintToABC()

    assert.equal(await lqtyTokenTester.balanceOf(A), dec(150, 18))

    await lqtyTokenTester.transfer(A, dec(37, 18), {from: B})

    assert.equal(await lqtyTokenTester.balanceOf(A), dec(187, 18))
  })

  it("transfer(): reverts if amount exceeds sender's balance", async () => {
    await mintToABC()

    assert.equal(await lqtyTokenTester.balanceOf(B), dec(100, 18))

    const txPromise = lqtyTokenTester.transfer(A, dec(101, 18), {from: B})
    assertRevert(txPromise)
  })

  it('transfer(): transferring to a blacklisted address reverts', async () => {
    await mintToABC()

    await assertRevert(lqtyTokenTester.transfer(lqtyTokenTester.address, 1, { from: A }))
    await assertRevert(lqtyTokenTester.transfer(ZERO_ADDRESS, 1, { from: A }))
    await assertRevert(lqtyTokenTester.transfer(communityIssuance.address, 1, { from: A }))
    await assertRevert(lqtyTokenTester.transfer(lqtyStaking.address, 1, { from: A }))
  })

  it("increaseAllowance(): increases an account's allowance by the correct amount", async () => {
    const allowance_A_Before = await lqtyTokenTester.allowance(B, A)
    assert.equal(allowance_A_Before, '0')

    await lqtyTokenTester.increaseAllowance(A, dec(100, 18), {from: B} )

    const allowance_A_After = await lqtyTokenTester.allowance(B, A)
    assert.equal(allowance_A_After, dec(100, 18))
  })

  it('sendToLQTYStaking(): changes balances of LQTYStaking and calling account by the correct amounts', async () => {
     // mint some tokens to A
     await lqtyTokenTester.unprotectedMint(A, dec(150, 18))
    
    // Check caller and LQTYStaking balance before
    const A_BalanceBefore = await lqtyTokenTester.balanceOf(A)
    assert.equal(A_BalanceBefore, dec(150,  18))
    const lqtyStakingBalanceBefore = await lqtyTokenTester.balanceOf(lqtyStaking.address)
    assert.equal(lqtyStakingBalanceBefore, '0')

    await lqtyTokenTester.unprotectedSendToLQTYStaking(A, dec(37, 18))

    // Check caller and LQTYStaking balance before
    const A_BalanceAfter = await lqtyTokenTester.balanceOf(A)
    assert.equal(A_BalanceAfter, dec(113, 18))
    const lqtyStakingBalanceAfter = await lqtyTokenTester.balanceOf(lqtyStaking.address)
    assert.equal(lqtyStakingBalanceAfter, dec(37,  18))
  })

  it('transfer(): LQTY token can not be sent to blacklisted addresses', async () => {
     // mint some tokens to A
     await lqtyTokenTester.unprotectedMint(A, dec(150, 18))
    assert.equal(await lqtyTokenTester.balanceOf(A), dec(150,  18))

    // Check LQTY tokens can't be sent to blacklisted addresses
    await assertRevert(lqtyTokenTester.transfer(lqtyTokenTester.address, dec(1, 18), { from: A }))
    await assertRevert(lqtyTokenTester.transfer(ZERO_ADDRESS, dec(1, 18), { from: A }))
    await assertRevert(lqtyTokenTester.transfer(communityIssuance.address, dec(1, 18), { from: A }))
    await assertRevert(lqtyTokenTester.transfer(lqtyStaking.address, dec(1, 18), { from: A }))
  })

  // EIP2612 tests

  it('Initializes PERMIT_TYPEHASH correctly', async () => {
    assert.equal(await lqtyTokenTester.permitTypeHash(), PERMIT_TYPEHASH)
  })

  it('Initializes DOMAIN_SEPARATOR correctly', async () => {
    assert.equal(await lqtyTokenTester.domainSeparator(), 
    getDomainSeparator(tokenName, lqtyTokenTester.address, chainId, tokenVersion))
  })

  it('Initial nonce for a given address is 0', async function () {
    assert.equal(toBN(await lqtyTokenTester.nonces(A)).toString(), '0');
  });
  
  it('permits and emits an Approval event (replay protected)', async () => {
    // Create the approval tx data
    const approve = {
      owner: A,
      spender: B,
      value: 1,
    }

    const deadline = 100000000000000
    const nonce = await lqtyTokenTester.nonces(approve.owner)
   
    // Get the EIP712 digest
    const digest = getPermitDigest(
      tokenName, lqtyTokenTester.address, 
      chainId, tokenVersion, 
      approve.owner, approve.spender,
      approve.value, nonce, deadline
    )
   
    const { v, r, s } = sign(digest, A_PrivateKey)
    
    // Approve it
    const receipt = await lqtyTokenTester.permit(
      approve.owner, approve.spender, approve.value, 
      deadline, v, hexlify(r), hexlify(s)
    )
    const event = receipt.logs[0]

    // Check that approval was successful
    assert.equal(event.event, 'Approval')
    assert.equal(await lqtyTokenTester.nonces(approve.owner), 1)
    assert.equal(await lqtyTokenTester.allowance(approve.owner, approve.spender), approve.value)
    
    // Check that we can not use re-use the same signature, since the user's nonce has been incremented (replay protection)
    assertRevert(lqtyTokenTester.permit(
      approve.owner, approve.spender, approve.value, 
      deadline, v, r, s), 'LUSD: Recovered address from the sig is not the owner')
   
    // Check that the zero address fails
    assertRevert(lqtyTokenTester.permit('0x0000000000000000000000000000000000000000', 
      approve.spender, approve.value, deadline, '0x99', r, s), 'LUSD: Recovered address from the sig is not the owner')
  })
})

