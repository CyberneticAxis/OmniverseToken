# Omniverse

## How to deploy Omniverse:

1. Deploy Omniverse with:
    + ownerAddr=Owner address multisig
2. Deploy OmniAdaptive with:
    + ownerAddr=Owner address multisig
    + omniverseAddr=Address of the created Omniverse contract
    + routerAddr=0x10ED43C718714eb63d5aA57B78B54704E256024E
    + pairedCoinAddr=0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56
    + treasuryAddr=Treasury address
3. Call the setOmniAdaptive function in the Omniverse contract with:
    + omniAdaptiveAddr=Address of the created OmniAdaptive contract
4. Create Pinksale/Unicrypt launch, including any token lock up, vesting, etc.
5. Call the setAllowTransfer function in the OmniAdaptive contract with:
   + addr=Pinksale/Unicrypt presale address
   + allowed=true
6. Call the setFeeExempt function in the OmniAdaptive contract with:
   + addr=Pinksale/Unicrypt presale address
   + enabled=true
7. Transfer any remaining tokens from the deployer address to the multisig
8. Call the setAllowTransfer function in the OmniAdaptive contract with:
   + addr=Deployer address
   + allowed=false
9. Call the setFeeExempt function in the OmniAdaptive contract with:
   + addr=Deployer address
   + enabled=false
10. Call the enableTransfers function in the OmniAdaptive contract
