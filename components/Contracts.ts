/* eslint-disable camelcase */
import {
    BancorArbitrage__factory,
    ERC20__factory,
    MockExchanges__factory,
    TestERC20Token__factory,
    TestBNT__factory,
    TestWETH__factory,
    TransparentUpgradeableProxyImmutable__factory
} from '../typechain-types';
import { deployOrAttach } from './ContractBuilder';
import { Signer } from 'ethers';

export * from '../typechain-types';

const getContracts = (signer?: Signer) => ({
    connect: (signer: Signer) => getContracts(signer),

    BancorArbitrage: deployOrAttach('BancorArbitrage', BancorArbitrage__factory, signer),
    ERC20: deployOrAttach('ERC20', ERC20__factory, signer),
    MockExchanges: deployOrAttach('MockExchanges', MockExchanges__factory, signer),
    TestERC20Token: deployOrAttach('TestERC20Token', TestERC20Token__factory, signer),
    TestWETH: deployOrAttach('TestWETH', TestWETH__factory, signer),
    TestBNT: deployOrAttach('TestBNT', TestBNT__factory, signer),
    TransparentUpgradeableProxyImmutable: deployOrAttach(
        'TransparentUpgradeableProxyImmutable',
        TransparentUpgradeableProxyImmutable__factory,
        signer
    )
});

export type ContractsType = ReturnType<typeof getContracts>;

export default getContracts();
