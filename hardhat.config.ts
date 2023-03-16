import { HardhatUserConfig } from 'hardhat/types';
import 'solidity-coverage';

const config: HardhatUserConfig = {
    networks: {
        hardhat: {

        }
    },
    solidity: {
        compilers: [
            {
                version: '0.8.13',
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200
                    },
                    metadata: {
                        bytecodeHash: 'none'
                    }
                }
            }
        ]
    },
};

export default config;
