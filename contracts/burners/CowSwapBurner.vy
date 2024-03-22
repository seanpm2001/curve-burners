# @version 0.3.10
"""
@title Burner
@notice Exchange tokens using CowSwap
"""


interface ERC20:
    def approve(_to: address, _value: uint256): nonpayable
    def transfer(_to: address, _value: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: nonpayable
    def balanceOf(_owner: address) -> uint256: view

ETH_ADDRESS: constant(address) = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE


enum Epoch:
    SLEEP  # 1
    COLLECT  # 2
    EXCHANGE  # 4
    FORWARD  # 8

interface FeeCollector:
    def target() -> ERC20: view
    def owner() -> address: view
    def emergency_owner() -> address: view
    def epoch_time_frame(epoch: Epoch, ts: uint256=block.timestamp) -> (uint256, uint256): view
    def exchange(_coins: DynArray[ERC20, MAX_COINS_LEN]) -> bool: view

MAX_COINS_LEN: constant(uint256) = 64
fee_collector: public(immutable(FeeCollector))


struct GPv2Order_Data:
    sellToken: ERC20  # token to sell
    buyToken: ERC20  # token to buy
    receiver: address  # receiver of the token to buy
    sellAmount: uint256
    buyAmount: uint256
    validTo: uint32  # timestamp until order is valid
    appData: bytes32  # extra info about the order
    feeAmount: uint256  # amount of fees in sellToken
    kind: bytes32  # buy or sell
    partiallyFillable: bool  # partially fillable (True) or fill-or-kill (False)
    sellTokenBalance: bytes32  # From where the sellToken balance is withdrawn
    buyTokenBalance: bytes32  # Where the buyToken is deposited

struct ConditionalOrderParams:
    # The contract implementing the conditional order logic
    handler: address  # self
    # Allows for multiple conditional orders of the same type and data
    salt: bytes32  # Not used for now
    # Data available to ALL discrete orders created by the conditional order
    staticData: Bytes[STATIC_DATA_LEN]  # Using coin address

struct PayloadStruct:
    proof: DynArray[bytes32, 32]
    params: ConditionalOrderParams
    offchainInput: Bytes[OFFCHAIN_DATA_LEN]

interface ComposableCow:
    def create(params: ConditionalOrderParams, dispatch: bool): nonpayable
    def domainSeparator() -> bytes32: view
    def isValidSafeSignature(
        safe: address, sender: address, _hash: bytes32, _domainSeparator: bytes32, typeHash: bytes32,
        encodeData: Bytes[15 * 32],
        payload: Bytes[(32 + 3 + 1 + 8) * 32],
    ) -> bytes4: view

STATIC_DATA_LEN: constant(uint256) = 20
OFFCHAIN_DATA_LEN: constant(uint256) = 1

vault_relayer: public(immutable(address))
composable_cow: public(immutable(ComposableCow))
app_data: public(immutable(bytes32))
sell_kind: immutable(bytes32)  # Surpluss in target coin
token_balance: immutable(bytes32)


# SignatureVerifierMuxer at
# https://github.com/rndlabs/safe-contracts/blob/11273c1f08eda18ed8ff49ec1d4abec5e451ff21/contracts/handler/extensible/SignatureVerifierMuxer.sol:
# method_id("domainVerifiers(address,bytes32)") == "0x51cad5ee"
# method_id("setDomainVerifier(bytes32,address)") == "0x3365582c"
SIGNATURE_VERIFIER_MUXER_INTERFACE: constant(bytes4) = 0x62af8dc2
ERC1271_MAGIC_VALUE: constant(bytes4) = 0x5fd7e97d
SUPPORTED_INTERFACES: constant(bytes4[4]) = [
    # ERC165: method_id("supportsInterface(bytes4)") == 0x01ffc9a7
    0x01ffc9a7,
    # Burner:
    #   method_id("burn(address[],address)") == 0x72a436a8
    #   method_id("push_target()") == 0x2eb078cd
    # 0x5c144e65
    0x5c144e65,
    # Interface corresponding to IConditionalOrderGenerator:
    #   method_id("getTradeableOrder(address,address,bytes32,bytes,bytes)") == 0xb8296fc4
    0xb8296fc4,
    # ERC1271 interface:
    #   method_id("isValidSignature(bytes32,bytes)") == 0x5fd7e97d
    ERC1271_MAGIC_VALUE,
]

created: public(HashMap[ERC20, bool])


@external
def __init__(_fee_collector: FeeCollector,
    _composable_cow: ComposableCow, _vault_relayer: address):
    """
    @notice Contract constructor
    @param _fee_collector FeeCollector to anchor to
    @param _composable_cow Address of ComposableCow contract
    @param _vault_relayer CowSwap's VaultRelayer contract address, all approves go there
    """
    fee_collector = _fee_collector
    vault_relayer = _vault_relayer
    composable_cow = _composable_cow

    # {"appCode":"Curve","metadata":{"hooks":{"version":"0.1.0"}},"version":"1.0.0"}
    app_data = 0x058315b749613051abcbf50cf2d605b4fa4a41554ec35d73fd058fc530da559f
    sell_kind = keccak256("sell")
    token_balance = keccak256("erc20")


@external
def burn(_coins: DynArray[ERC20, MAX_COINS_LEN], _receiver: address):
    """
    @notice Post hook after collect to register coins for burn
    @dev Registers new orders in ComposableCow
    @param _coins Which coins to burn
    @param _receiver Receiver of profit. Might be needed for multiple transactions actions, here is ignored
    """
    for coin in _coins:
        if not self.created[coin]:
            composable_cow.create(ConditionalOrderParams({
                handler: self,
                salt: empty(bytes32),
                staticData: concat(b"", convert(coin.address, bytes20)),
            }), True)
            coin.approve(vault_relayer, max_value(uint256))
            self.created[coin] = True


@view
@internal
def _get_order(sell_token: ERC20) -> GPv2Order_Data:
    buy_token: ERC20 = fee_collector.target()
    return GPv2Order_Data({
        sellToken: sell_token,  # token to sell
        buyToken: buy_token,  # token to buy
        receiver: fee_collector.address,  # receiver of the token to buy
        sellAmount: 0,  # Set later
        buyAmount: 1,
        validTo: convert(fee_collector.epoch_time_frame(Epoch.EXCHANGE)[1], uint32),  # timestamp until order is valid
        appData: app_data,  # extra info about the order
        feeAmount: 0,  # amount of fees in sellToken
        kind: sell_kind,  # buy or sell
        partiallyFillable: True,  # partially fillable (True) or fill-or-kill (False)
        sellTokenBalance: token_balance,  # From where the sellToken balance is withdrawn
        buyTokenBalance: token_balance,  # Where the buyToken is deposited
    })


@view
@external
def get_current_order(sell_token: address=empty(address)) -> GPv2Order_Data:
    """
    @notice Get current order parameters
    @notice sell_token Address of possible sell token
    """
    return self._get_order(ERC20(sell_token))


@view
@external
def getTradeableOrder(_owner: address, _sender: address, _ctx: bytes32, _static_input: Bytes[STATIC_DATA_LEN], _offchain_input: Bytes[OFFCHAIN_DATA_LEN]) -> GPv2Order_Data:
    """
    @notice Generate order for WatchTower
    @dev _owner, _sender, _ctx, _offchain_input are ignored
    @param _owner Owner of order (self)
    @param _sender `msg.sender` context calling `isValidSignature`
    @param _ctx Execution context
    @param _static_input sellToken encoded as bytes(Bytes[20])
    @param _offchain_input Not used, zero-length bytes
    """
    sell_token: ERC20 = ERC20(convert(convert(_static_input, bytes20), address))
    order: GPv2Order_Data = self._get_order(sell_token)
    order.sellAmount = sell_token.balanceOf(self)

    if order.sellAmount == 0 or not fee_collector.exchange([sell_token]):
        start: uint256 = 0
        end: uint256 = 0
        start, end = fee_collector.epoch_time_frame(Epoch.EXCHANGE)
        if block.timestamp >= start:
            start, end = fee_collector.epoch_time_frame(Epoch.EXCHANGE, block.timestamp + 7 * 24 * 3600)
        error_str: String[15 + 256 + 13] = concat("PollTryAtEpoch(", uint2str(start), ",)")
        raise error_str

    return order


@view
@external
def verify(
    _owner: address,
    _sender: address,
    _hash: bytes32,
    _domain_separator: bytes32,
    _ctx: bytes32,
    _static_input: Bytes[STATIC_DATA_LEN],
    _offchain_input: Bytes[OFFCHAIN_DATA_LEN],
    _order: GPv2Order_Data,
):
    """
    @notice Verify order
    @dev Called from ComposableCow. _owner, _sender, _hash, _domain_separator, _ctx are ignored.
    @param _owner Owner of conditional order (self)
    @param _sender `msg.sender` context calling `isValidSignature`
    @param _hash `EIP-712` order digest
    @param _domain_separator `EIP-712` domain separator
    @param _ctx Execution context
    @param _static_input ConditionalOrder's staticData (coin address)
    @param _offchain_input Conditional order type-specific data NOT known at time of creation for a specific discrete order (or zero-length bytes if not applicable)
    @param _order The proposed discrete order's `GPv2Order.Data` struct
    """
    sell_token: ERC20 = ERC20(convert(convert(_static_input, bytes20), address))
    assert fee_collector.exchange([sell_token]), "OrderNotValid(NotAllowed)"
    assert _offchain_input == b"", "OrderNotValid(NonZeroOffchainInput)"
    order: GPv2Order_Data = self._get_order(sell_token)
    order.sellAmount = _order.sellAmount  # Any amount allowed
    order.buyAmount = _order.buyAmount  # Price is discovered within CowSwap competition
    assert _abi_encode(order) == _abi_encode(_order), "OrderNotValid(BadOrder)"


@view
@external
def isValidSignature(_hash: bytes32, signature: Bytes[1792]) -> bytes4:
    """
    @notice ERC1271 signature verifier method
    @dev Forwards query to ComposableCow
    @param _hash Hash of signed object. Ignored here
    @param signature Signature for the object. (GPv2Order.Data, PayloadStruct) here
    @return `ERC1271_MAGIC_VALUE` if signature is OK
    """
    order: GPv2Order_Data = empty(GPv2Order_Data)
    payload: PayloadStruct = empty(PayloadStruct)
    order, payload = _abi_decode(signature, (GPv2Order_Data, PayloadStruct))

#    domain_separator: bytes32 = composable_cow.domainSeparator()
#    hash: bytes32 = keccak256(
#        concat(b"\x19\x01", domain_separator, keccak256(
#            concat(b"d5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489",
#                _abi_encode(order),
#            )
#        ))
#    )
#    if hash != _hash:
#        raise "InvalidHash()"

    return composable_cow.isValidSafeSignature(self, msg.sender, _hash, composable_cow.domainSeparator(), empty(bytes32),
        _abi_encode(order),
        _abi_encode(payload),
    )


@external
def push_target() -> uint256:
    """
    @notice In case target coin is left in contract can be pushed to forward
    @return Amount of coin pushed further
    """
    target: ERC20 = fee_collector.target()
    amount: uint256 = target.balanceOf(self)
    if amount > 0:
        target.transfer(fee_collector.address, amount)
    return amount


@pure
@external
def supportsInterface(_interface_id: bytes4) -> bool:
    """
    @dev Interface identification is specified in ERC-165.
    Fails on SignatureVerifierMuxer for compatability with ComposableCow.
    @param _interface_id Id of the interface
    """
    assert _interface_id != SIGNATURE_VERIFIER_MUXER_INTERFACE
    return _interface_id in SUPPORTED_INTERFACES


@external
def recover(_coins: DynArray[ERC20, MAX_COINS_LEN]):
    """
    @notice Recover ERC20 tokens or Ether from this contract
    @dev Callable only by owner and emergency owner
    @param _coins Token addresses
    """
    assert msg.sender in [fee_collector.owner(), fee_collector.emergency_owner()], "Only owner"

    for coin in _coins:
        if coin.address == ETH_ADDRESS:
            raw_call(fee_collector.address, b"", value=self.balance)
        else:
            coin.transfer(fee_collector.address, coin.balanceOf(self))  # do not need safe transfer
