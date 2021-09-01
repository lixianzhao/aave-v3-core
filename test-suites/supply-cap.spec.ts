import { expect } from 'chai';
import { utils } from 'ethers';
import { MAX_UINT_AMOUNT, MAX_SUPPLY_CAP } from '../helpers/constants';
import { ProtocolErrors } from '../helpers/types';
import { TestEnv, makeSuite } from './helpers/make-suite';

makeSuite('Supply Cap', (testEnv: TestEnv) => {
  const { VL_SUPPLY_CAP_EXCEEDED, RC_INVALID_SUPPLY_CAP } = ProtocolErrors;

  let USDC_DECIMALS;
  let DAI_DECIMALS;
  let WETH_DECIMALS;

  before(async () => {
    const { weth, pool, dai, usdc } = testEnv;

    USDC_DECIMALS = await usdc.decimals();
    DAI_DECIMALS = await dai.decimals();
    WETH_DECIMALS = await weth.decimals();

    const mintedAmount = utils.parseEther('1000000000');
    await dai.mint(mintedAmount);
    await weth.mint(mintedAmount);
    await usdc.mint(mintedAmount);

    await dai.approve(pool.address, MAX_UINT_AMOUNT);
    await weth.approve(pool.address, MAX_UINT_AMOUNT);
    await usdc.approve(pool.address, MAX_UINT_AMOUNT);
  });

  it('Reserves should initially have supply cap disabled (supplyCap = 0)', async () => {
    const { dai, usdc, helpersContract } = testEnv;

    let usdcSupplyCap = (await helpersContract.getReserveCaps(usdc.address)).supplyCap;
    let daiSupplyCap = (await helpersContract.getReserveCaps(dai.address)).supplyCap;

    expect(usdcSupplyCap).to.be.equal('0');
    expect(daiSupplyCap).to.be.equal('0');
  });

  it('Supply 1000 Dai, 1000 USDC and 1000 WETH', async () => {
    const { weth, pool, dai, usdc, deployer } = testEnv;

    const suppliedAmount = '1000';

    await pool.deposit(
      usdc.address,
      await utils.parseUnits(suppliedAmount, USDC_DECIMALS),
      deployer.address,
      0
    );

    await pool.deposit(
      dai.address,
      await utils.parseUnits(suppliedAmount, DAI_DECIMALS),
      deployer.address,
      0
    );
    await pool.deposit(
      weth.address,
      await utils.parseUnits(suppliedAmount, WETH_DECIMALS),
      deployer.address,
      0
    );
  });

  it('Sets the supply cap for WETH and DAI to 1000 Unit, leaving 0 Units to reach the limit', async () => {
    const { configurator, dai, usdc, helpersContract } = testEnv;

    const newCap = '1000';

    expect(await configurator.setSupplyCap(usdc.address, newCap))
      .to.emit(configurator, 'SupplyCapChanged')
      .withArgs(usdc.address, newCap);
    expect(await configurator.setSupplyCap(dai.address, newCap))
      .to.emit(configurator, 'SupplyCapChanged')
      .withArgs(dai.address, newCap);

    const usdcSupplyCap = (await helpersContract.getReserveCaps(usdc.address)).supplyCap;
    const daiSupplyCap = (await helpersContract.getReserveCaps(dai.address)).supplyCap;

    expect(usdcSupplyCap).to.be.equal(newCap);
    expect(daiSupplyCap).to.be.equal(newCap);
  });

  it('Tries to supply any DAI or USDC (> SUPPLY_CAP) and reverts', async () => {
    const { usdc, pool, dai, deployer } = testEnv;
    const suppliedAmount = '10';

    await expect(
      pool.deposit(usdc.address, suppliedAmount, deployer.address, 0)
    ).to.be.revertedWith(VL_SUPPLY_CAP_EXCEEDED);

    await expect(
      pool.deposit(
        dai.address,
        await utils.parseUnits(suppliedAmount, DAI_DECIMALS),
        deployer.address,
        0
      )
    ).to.be.revertedWith(VL_SUPPLY_CAP_EXCEEDED);
  });

  it('Tries to set the supply cap for USDC and DAI to > MAX_SUPPLY_CAP and reverts', async () => {
    const { configurator, usdc, dai } = testEnv;
    const newCap = Number(MAX_SUPPLY_CAP) + 1;

    await expect(configurator.setSupplyCap(usdc.address, newCap)).to.be.revertedWith(
      RC_INVALID_SUPPLY_CAP
    );
    await expect(configurator.setSupplyCap(dai.address, newCap)).to.be.revertedWith(
      RC_INVALID_SUPPLY_CAP
    );
  });

  it('Sets the supply cap for usdc and DAI to 1110 Units, leaving 110 Units to reach the limit', async () => {
    const { configurator, usdc, dai, helpersContract } = testEnv;
    const newCap = '1110';

    expect(await configurator.setSupplyCap(usdc.address, newCap))
      .to.emit(configurator, 'SupplyCapChanged')
      .withArgs(usdc.address, newCap);
    expect(await configurator.setSupplyCap(dai.address, newCap))
      .to.emit(configurator, 'SupplyCapChanged')
      .withArgs(dai.address, newCap);

    const usdcSupplyCap = (await helpersContract.getReserveCaps(usdc.address)).supplyCap;
    const daiSupplyCap = (await helpersContract.getReserveCaps(dai.address)).supplyCap;

    expect(usdcSupplyCap).to.be.equal(newCap);
    expect(daiSupplyCap).to.be.equal(newCap);
  });

  it('Supply 10 DAI and 10 USDC, leaving 100 Units to reach the limit', async () => {
    const { usdc, pool, dai, deployer } = testEnv;

    const suppliedAmount = '10';
    await pool.deposit(
      usdc.address,
      await utils.parseUnits(suppliedAmount, USDC_DECIMALS),
      deployer.address,
      0
    );

    await pool.deposit(
      dai.address,
      await utils.parseUnits(suppliedAmount, DAI_DECIMALS),
      deployer.address,
      0
    );
  });

  it('Tries to supply 100 DAI and 100 USDC (= SUPPLY_CAP) and reverts', async () => {
    const { usdc, pool, dai, deployer } = testEnv;

    const suppliedAmount = '100';

    await expect(
      pool.deposit(
        usdc.address,
        await utils.parseUnits(suppliedAmount, USDC_DECIMALS),
        deployer.address,
        0
      )
    ).to.be.revertedWith(VL_SUPPLY_CAP_EXCEEDED);

    await expect(
      pool.deposit(
        dai.address,
        await utils.parseUnits(suppliedAmount, DAI_DECIMALS),
        deployer.address,
        0
      )
    ).to.be.revertedWith(VL_SUPPLY_CAP_EXCEEDED);
  });

  it('Supply 99 DAI and 99 USDC (< SUPPLY_CAP), leaving 1 Units to reach the limit', async () => {
    const { usdc, pool, dai, deployer } = testEnv;

    const suppliedAmount = '99';
    await pool.deposit(
      usdc.address,
      await utils.parseUnits(suppliedAmount, USDC_DECIMALS),
      deployer.address,
      0
    );

    await pool.deposit(
      dai.address,
      await utils.parseUnits(suppliedAmount, DAI_DECIMALS),
      deployer.address,
      0
    );
  });

  it('Raises the supply cap for USDC and DAI to 2000 Units, leaving 800 Units to reach the limit', async () => {
    const { configurator, usdc, dai, helpersContract } = testEnv;

    const newCap = '2000';

    expect(await configurator.setSupplyCap(usdc.address, newCap))
      .to.emit(configurator, 'SupplyCapChanged')
      .withArgs(usdc.address, newCap);
    expect(await configurator.setSupplyCap(dai.address, newCap))
      .to.emit(configurator, 'SupplyCapChanged')
      .withArgs(dai.address, newCap);

    const usdcSupplyCap = (await helpersContract.getReserveCaps(usdc.address)).supplyCap;
    const daiSupplyCap = (await helpersContract.getReserveCaps(dai.address)).supplyCap;

    expect(usdcSupplyCap).to.be.equal(newCap);
    expect(daiSupplyCap).to.be.equal(newCap);
  });

  it('Supply 100 DAI and 100 USDC, leaving 700 Units to reach the limit', async () => {
    const { usdc, pool, dai, deployer } = testEnv;

    const suppliedAmount = '100';
    await pool.deposit(
      usdc.address,
      await utils.parseUnits(suppliedAmount, USDC_DECIMALS),
      deployer.address,
      0
    );

    await pool.deposit(
      dai.address,
      await utils.parseUnits(suppliedAmount, DAI_DECIMALS),
      deployer.address,
      0
    );
  });

  it('Lowers the supply cap for USDC and DAI to 1200 Units (suppliedAmount > supplyCap)', async () => {
    const { configurator, usdc, dai, helpersContract } = testEnv;

    const newCap = '1200';

    expect(await configurator.setSupplyCap(usdc.address, newCap))
      .to.emit(configurator, 'SupplyCapChanged')
      .withArgs(usdc.address, newCap);
    expect(await configurator.setSupplyCap(dai.address, newCap))
      .to.emit(configurator, 'SupplyCapChanged')
      .withArgs(dai.address, newCap);

    const usdcSupplyCap = (await helpersContract.getReserveCaps(usdc.address)).supplyCap;
    const daiSupplyCap = (await helpersContract.getReserveCaps(dai.address)).supplyCap;

    expect(usdcSupplyCap).to.be.equal(newCap);
    expect(daiSupplyCap).to.be.equal(newCap);
  });

  it('Tries to supply 100 DAI and 100 USDC (> SUPPLY_CAP) and reverts', async () => {
    const { usdc, pool, dai, deployer } = testEnv;

    const suppliedAmount = '100';

    await expect(
      pool.deposit(
        usdc.address,
        await utils.parseUnits(suppliedAmount, USDC_DECIMALS),
        deployer.address,
        0
      )
    ).to.be.revertedWith(VL_SUPPLY_CAP_EXCEEDED);

    await expect(
      pool.deposit(
        dai.address,
        await utils.parseUnits(suppliedAmount, DAI_DECIMALS),
        deployer.address,
        0
      )
    ).to.be.revertedWith(VL_SUPPLY_CAP_EXCEEDED);
  });

  it('Raises the supply cap for USDC and DAI to MAX_SUPPLY_CAP', async () => {
    const { configurator, usdc, dai, helpersContract } = testEnv;

    const newCap = MAX_SUPPLY_CAP;

    expect(await configurator.setSupplyCap(usdc.address, newCap))
      .to.emit(configurator, 'SupplyCapChanged')
      .withArgs(usdc.address, newCap);
    expect(await configurator.setSupplyCap(dai.address, newCap))
      .to.emit(configurator, 'SupplyCapChanged')
      .withArgs(dai.address, newCap);

    const usdcSupplyCap = (await helpersContract.getReserveCaps(usdc.address)).supplyCap;
    const daiSupplyCap = (await helpersContract.getReserveCaps(dai.address)).supplyCap;

    expect(usdcSupplyCap).to.be.equal(newCap);
    expect(daiSupplyCap).to.be.equal(newCap);
  });

  it('Supply 100 DAI and 100 USDC', async () => {
    const { usdc, pool, dai, deployer } = testEnv;

    const suppliedAmount = '100';
    await pool.deposit(
      usdc.address,
      await utils.parseUnits(suppliedAmount, USDC_DECIMALS),
      deployer.address,
      0
    );

    await pool.deposit(
      dai.address,
      await utils.parseUnits(suppliedAmount, DAI_DECIMALS),
      deployer.address,
      0
    );
  });
});
