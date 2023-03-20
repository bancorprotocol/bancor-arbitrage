import { BancorArbitrage, ProxyAdmin } from '../../components/Contracts';
import { DeployedContracts, describeDeployment } from '../../utils/Deploy';
import { toPPM, toWei } from '../../utils/Types';
import { expect } from 'chai';

describeDeployment(__filename, () => {
    let proxyAdmin: ProxyAdmin;
    let bancorArbitrage: BancorArbitrage;

    beforeEach(async () => {
        proxyAdmin = await DeployedContracts.ProxyAdmin.deployed();
        bancorArbitrage = await DeployedContracts.BancorArbitrage.deployed();
    });

    it('should upgrade correctly', async () => {
        expect(await proxyAdmin.getProxyAdmin(bancorArbitrage.address)).to.equal(proxyAdmin.address);
        expect(await bancorArbitrage.version()).to.equal(2);

        const arbRewards = await bancorArbitrage.rewards();
        expect(arbRewards.percentagePPM).to.equal(toPPM(10));
        expect(arbRewards.maxAmount).to.equal(toWei(100));
    });
});
