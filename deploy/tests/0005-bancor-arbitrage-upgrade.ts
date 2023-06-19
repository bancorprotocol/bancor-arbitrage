import { shouldHaveGap } from '../../utils/Proxy';
import { BancorArbitrage, ProxyAdmin } from '../../components/Contracts';
import { DeployedContracts, describeDeployment } from '../../utils/Deploy';
import { toPPM, toWei } from '../../utils/Types';
import { expect } from 'chai';
import { ethers } from 'hardhat';

describeDeployment(__filename, () => {
    let proxyAdmin: ProxyAdmin;
    let bancorArbitrage: BancorArbitrage;

    shouldHaveGap('BancorArbitrage', '_rewards');

    beforeEach(async () => {
        proxyAdmin = await DeployedContracts.ProxyAdmin.deployed();
        bancorArbitrage = await DeployedContracts.BancorArbitrage.deployed();
    });

    it('should upgrade correctly', async () => {
        expect(await proxyAdmin.getProxyAdmin(bancorArbitrage.address)).to.equal(proxyAdmin.address);
        expect(await bancorArbitrage.version()).to.equal(4);
        const implementationAddress = await proxyAdmin.getProxyImplementation(bancorArbitrage.address);
        const bancorArbitrageImplementation: BancorArbitrage = await ethers.getContractAt(
            'BancorArbitrage',
            implementationAddress
        );

        const arbRewards = await bancorArbitrage.rewards();
        expect(arbRewards.percentagePPM).to.equal(toPPM(50));
        expect(arbRewards.maxAmount.toString()).to.equal(toWei(1000).toString());

        // test implementation has been initialized
        await expect(bancorArbitrageImplementation.initialize()).to.be.rejectedWith('execution reverted');
    });
});
