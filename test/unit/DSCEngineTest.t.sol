// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address weth;
    address wbtc;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.getActiveNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    // Price Tests
    function testGetUSDValue() public view {
        uint256 ethAmount = 15 ether;
        uint256 expectedUsd = 30000 ether;
        uint256 actualUsd = engine.getUSDValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    // DepositCollateral Tests
    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_MustBeMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public depositedCollateral {
        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 maxDscToMint =
            (collateralValueInUsd * engine.getLiquidationThreshold()) / engine.getLiquidationPrecision();

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorBroken.selector);
        engine.mintDsc(maxDscToMint + 1);
        vm.stopPrank();
    }

    // Getter function tests
    function testGetHealthFactor() public depositedCollateral {
        uint256 healthFactor = engine.getHealthFactor(USER);
        assertEq(healthFactor, type(uint256).max); // No DSC minted, so health factor should be max
    }

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 balance = engine.getCollateralBalanceOfUser(USER, weth);
        assertEq(balance, AMOUNT_COLLATERAL);
    }

    function testGetCollateralTokens() public view {
        address[] memory tokens = engine.getCollateralTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], weth);
        assertEq(tokens[1], wbtc);
    }

    function testGetDscMinted() public view {
        uint256 dscMinted = engine.getDscMinted(USER);
        assertEq(dscMinted, 0);
    }

    function testGetPriceFeed() public view {
        address priceFeed = engine.getPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetLiquidationThreshold() public view {
        uint256 threshold = engine.getLiquidationThreshold();
        assertEq(threshold, 50);
    }

    function testGetLiquidationBonus() public view {
        uint256 bonus = engine.getLiquidationBonus();
        assertEq(bonus, 10);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, 1e18);
    }

    function testGetDsc() public view {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    // Mint DSC Tests
    function testCanMintDsc() public depositedCollateral {
        uint256 amountToMint = 1000 ether;
        vm.startPrank(USER);
        engine.mintDsc(amountToMint);
        vm.stopPrank();

        uint256 dscMinted = engine.getDscMinted(USER);
        assertEq(dscMinted, amountToMint);
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_MustBeMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    // Burn DSC Tests
    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        engine.mintDsc(1000 ether);
        vm.stopPrank();
        _;
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(engine), 500 ether);
        engine.burnDsc(500 ether);
        vm.stopPrank();

        uint256 dscMinted = engine.getDscMinted(USER);
        assertEq(dscMinted, 500 ether);
    }

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_MustBeMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    // Redeem Collateral Tests
    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 balance = engine.getCollateralBalanceOfUser(USER, weth);
        assertEq(balance, 0);
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_MustBeMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    // Health Factor Tests
    function testHealthFactorCalculation() public depositedCollateralAndMintedDsc {
        uint256 healthFactor = engine.getHealthFactor(USER);
        // With 10 ETH collateral ($20,000) and 1000 DSC minted
        // Health factor = (20000 * 50 / 100) / 1000 = 10
        assertEq(healthFactor, 10e18);
    }

    // Liquidation Tests
    function testRevertsIfHealthFactorOk() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDsc(1000 ether); // Safe amount, health factor should be good
        vm.stopPrank();

        // Setup liquidator with collateral and DSC
        address liquidator = makeAddr("liquidator");
        ERC20Mock(weth).mint(liquidator, STARTING_ERC20_BALANCE);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), STARTING_ERC20_BALANCE);
        engine.depositCollateral(weth, STARTING_ERC20_BALANCE);
        engine.mintDsc(100 ether); // Liquidator mints their own DSC
        dsc.approve(address(engine), 100 ether);
        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorOk.selector);
        engine.liquidate(weth, USER, 100 ether);
        vm.stopPrank();
    }

    function testCalculateHealthFactorBelowOne() public view {
        // Test the health factor calculation directly
        uint256 totalDscMinted = 18000 ether;
        uint256 collateralValueInUsd = 20000 ether; // 10 ETH at $2000 each
        uint256 healthFactor = engine.calculateHealthFactor(totalDscMinted, collateralValueInUsd);

        // Health factor should be (20000 * 50 / 100) / 18000 = 0.555...
        assertLt(healthFactor, engine.getMinHealthFactor());
    }

    // Combined function tests
    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1000 ether);
        vm.stopPrank();

        uint256 collateralBalance = engine.getCollateralBalanceOfUser(USER, weth);
        uint256 dscMinted = engine.getDscMinted(USER);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
        assertEq(dscMinted, 1000 ether);
    }

    function testRedeemCollateralForDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(engine), 500 ether);
        engine.redeemCollateralForDsc(weth, 1 ether, 500 ether);
        vm.stopPrank();

        uint256 collateralBalance = engine.getCollateralBalanceOfUser(USER, weth);
        uint256 dscMinted = engine.getDscMinted(USER);
        assertEq(collateralBalance, AMOUNT_COLLATERAL - 1 ether);
        assertEq(dscMinted, 500 ether);
    }
}
