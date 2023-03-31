import { DeployedContracts, InstanceName, isMainnet, setDeploymentMetadata, upgradeProxy } from '../../utils/Deploy';
import { DeployFunction } from 'hardhat-deploy/types';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { BancorArbitrage } from '../../typechain-types';

const func: DeployFunction = async ({ getNamedAccounts }: HardhatRuntimeEnvironment) => {
    const {
        deployer,
        uniswapV2Router02,
        uniswapV3Router,
        sushiSwapRouter,
        bnt,
        dustWallet,
        bancorNetworkV2,
        bancorNetworkV3
    } = await getNamedAccounts();

    const exchanges: BancorArbitrage.ExchangesStruct = {
        bancorNetworkV2,
        bancorNetworkV3,
        uniV2Router: uniswapV2Router02,
        uniV3Router: uniswapV3Router,
        sushiswapRouter: sushiSwapRouter,
        carbonController: bancorNetworkV3
    };

    if (isMainnet()) {
        await upgradeProxy(
            {
                name: InstanceName.BancorArbitrage,
                from: deployer,
                args: [bnt, dustWallet, exchanges]
            },
            true
        );
    } else {
        const mockExchanges = await DeployedContracts.MockExchanges.deployed();

        await upgradeProxy(
            {
                name: InstanceName.BancorArbitrage,
                from: deployer,
                args: [
                    bnt,
                    dustWallet,
                    {
                        bancorNetworkV2: mockExchanges.address,
                        bancorNetworkV3,
                        uniV2Router: mockExchanges.address,
                        uniV3Router: mockExchanges.address,
                        sushiswapRouter: mockExchanges.address,
                        carbonController: mockExchanges.address
                    }
                ]
            },
            true
        );
    }

    return true;
};

export default setDeploymentMetadata(__filename, func);
