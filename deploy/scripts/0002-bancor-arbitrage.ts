import { DeployedContracts, deployProxy, InstanceName, isMainnet, setDeploymentMetadata } from '../../utils/Deploy';
import { DeployFunction } from 'hardhat-deploy/types';
import { HardhatRuntimeEnvironment } from 'hardhat/types';

const func: DeployFunction = async ({ getNamedAccounts }: HardhatRuntimeEnvironment) => {
    const { deployer, uniswapV2Router02, uniswapV3Router, sushiSwapRouter, bnt, bancorNetworkV2, bancorNetworkV3 } =
        await getNamedAccounts();

    if (isMainnet()) {
        await deployProxy({
            name: InstanceName.BancorArbitrage,
            from: deployer,
            args: [bnt, bancorNetworkV2, bancorNetworkV3, uniswapV2Router02, uniswapV3Router, sushiSwapRouter]
        });
    } else {
        const mockExchanges = await DeployedContracts.MockExchanges.deployed();

        await deployProxy({
            name: InstanceName.BancorArbitrage,
            from: deployer,
            args: [
                bnt,
                mockExchanges.address,
                bancorNetworkV3,
                mockExchanges.address,
                mockExchanges.address,
                mockExchanges.address
            ]
        });
    }

    return true;
};

export default setDeploymentMetadata(__filename, func);
