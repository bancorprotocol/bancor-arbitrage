import {
    DeployedContracts,
    InstanceName,
    execute,
    isMainnet,
    setDeploymentMetadata,
    upgradeProxy
} from '../../utils/Deploy';
import { MIN_BNT_BURN } from '../../utils/Constants';
import { DeployFunction } from 'hardhat-deploy/types';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { BancorArbitrage } from '../../typechain-types';
import { ethers } from 'hardhat';

const func: DeployFunction = async ({ getNamedAccounts }: HardhatRuntimeEnvironment) => {
    const {
        deployer,
        uniswapV2Router02,
        uniswapV3Router,
        sushiSwapRouter,
        bnt,
        dustWallet,
        bancorNetworkV2,
        bancorNetworkV3,
        carbonController
    } = await getNamedAccounts();

    const exchanges: BancorArbitrage.ExchangesStruct = {
        bancorNetworkV2,
        bancorNetworkV3,
        uniV2Router: uniswapV2Router02,
        uniV3Router: uniswapV3Router,
        sushiswapRouter: sushiSwapRouter,
        carbonController
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

    // set min BNT burn
    await execute({
        name: InstanceName.BancorArbitrage,
        methodName: 'setMinBurn',
        args: [MIN_BNT_BURN],
        from: deployer
    });

    return true;
};

export default setDeploymentMetadata(__filename, func);
