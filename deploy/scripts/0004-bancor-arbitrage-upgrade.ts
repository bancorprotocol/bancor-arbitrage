import { DeployedContracts, InstanceName, isMainnet, setDeploymentMetadata, upgradeProxy } from '../../utils/Deploy';
import { DeployFunction } from 'hardhat-deploy/types';
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { BancorArbitrage } from '../../typechain-types';

const func: DeployFunction = async ({ getNamedAccounts }: HardhatRuntimeEnvironment) => {
    const { deployer, uniswapV2Router02, uniswapV3Router, sushiSwapRouter } = await getNamedAccounts();

    const bntAddress = '0x1F573D6Fb3F13d689FF844B4cE37794d79a7FF1C';
    const dustWallet = '0xeBcC959479634EEC5A4d7162e36f8B8cc763f491';
    const bancorNetworkV2Address = '0x2F9EC37d6CcFFf1caB21733BdaDEdE11c823cCB0';
    const bancorNetworkV3Address = '0xeEF417e1D5CC832e619ae18D2F140De2999dD4fB';

    const exchanges: BancorArbitrage.ExchangesStruct = {
        bancorNetworkV2: bancorNetworkV2Address,
        bancorNetworkV3: bancorNetworkV3Address,
        uniV2Router: uniswapV2Router02,
        uniV3Router: uniswapV3Router,
        sushiswapRouter: sushiSwapRouter,
        carbonController: bancorNetworkV3Address
    };

    if (isMainnet()) {
        await upgradeProxy(
            {
                name: InstanceName.BancorArbitrage,
                from: deployer,
                args: [bntAddress, dustWallet, exchanges]
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
                    bntAddress,
                    dustWallet,
                    {
                        bancorNetworkV2: mockExchanges.address,
                        bancorNetworkV3: bancorNetworkV3Address,
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
