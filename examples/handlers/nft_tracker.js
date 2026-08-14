/**
 * NFT 铸造与交易追踪 —— ERC721 Transfer
 *
 * 配置（config.toml）：
 *   [[contracts]]
 *   name = "BoredApe"                # NFT 合集名
 *   address = "0x..."               # ERC721 合约地址
 *   abi_path = "./abis/erc721.abi"
 *   events = ["Transfer"]
 *
 * Transfer 事件签名（ERC721）：
 *   Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
 */
ponder.on("BoredApe:Transfer", (event) => {
  const { from, to, tokenId } = event.args;
  const blockNumber = event.block.number;
  const id = BigInt(tokenId || "0x0");

  if (from === "0x0000000000000000000000000000000000000000") {
    console.log(`[NFT] 区块 ${blockNumber} | 铸造 #${id} -> ${to.slice(0, 10)}`);
  } else if (to === "0x0000000000000000000000000000000000000000") {
    console.log(`[NFT] 区块 ${blockNumber} | 销毁 #${id} <- ${from.slice(0, 10)}`);
  } else {
    console.log(`[NFT] 区块 ${blockNumber} | 交易 #${id}: ${from.slice(0, 10)} -> ${to.slice(0, 10)}`);
  }
});
