
const { ethers, run } = require("hardhat");
const save = require("../save_deployed");
const loadDeployed = require("../load_deployed");

async function main() {
  let deployer, user2;

  const { chainId } = await ethers.provider.getNetwork();
  let networkName = "local";
  if(chainId == 1) networkName = "mainnet";
  if(chainId == 4) networkName = "rinkeby";

  [deployer, user2] = await ethers.getSigners();
  // console.log('deployer',deployer.address);
  // console.log('user2',user2.address);

  let deployInfo = {
    name: "",
    address: ""
  }

  const RewardProgramVault = await ethers.getContractFactory("RewardProgramVault");
  const rewardProgramVault  = await RewardProgramVault.deploy();

  let tx0 = await rewardProgramVault.deployed();
  console.log("RewardProgramVault tx0:", tx0.deployTransaction.hash);
  console.log("RewardProgramVault deployed to:", rewardProgramVault.address);

  deployInfo = {
      name: "RewardProgramVault",
      address: rewardProgramVault.address
  }

  console.log(networkName," : ", deployInfo);
  save(networkName, deployInfo);

  if(chainId == 1 || chainId == 4)
    await run("verify", {
      address: rewardProgramVault.address,
      constructorArgsParams: [],
    });
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
