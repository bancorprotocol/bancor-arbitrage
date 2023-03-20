import { DeployedContracts, InstanceName, isMainnet, setDeploymentMetadata, upgradeProxy } from '../../utils/Deploy';
import { DeployFunction } from 'hardhat-deploy/types';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

const func: DeployFunction = async ({ getNamedAccounts }: HardhatRuntimeEnvironment) => {
    const { deployer, uniswapV2Router02, uniswapV3Router, sushiSwapRouter } = await getNamedAccounts();

    const bntAddress = '0x1F573D6Fb3F13d689FF844B4cE37794d79a7FF1C';
    const bancorNetworkV2Address = '0x2F9EC37d6CcFFf1caB21733BdaDEdE11c823cCB0';
    const bancorNetworkV3Address = '0xeEF417e1D5CC832e619ae18D2F140De2999dD4fB';

    if (isMainnet()) {
        await upgradeProxy({
            name: InstanceName.BancorArbitrage,
            from: deployer,
            args: [
                bntAddress,
                bancorNetworkV2Address,
                bancorNetworkV3Address,
                uniswapV2Router02,
                uniswapV3Router,
                sushiSwapRouter
            ]
        });
    } else {
        const mockExchanges = await DeployedContracts.MockExchanges.deployed();

        await upgradeProxy({
            name: InstanceName.BancorArbitrage,
            from: deployer,
            args: [
                bntAddress,
                mockExchanges.address,
                bancorNetworkV3Address,
                mockExchanges.address,
                mockExchanges.address,
                mockExchanges.address
            ]
        });
    }

    return true;
};

export default setDeploymentMetadata(__filename, func);
