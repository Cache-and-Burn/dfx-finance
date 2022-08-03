
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../src/interfaces/IAssimilator.sol";
import "../src/interfaces/IOracle.sol";
import "../src/interfaces/IERC20Detailed.sol";
import "../src/AssimilatorFactory.sol";
import "../src/CurveFactoryV2.sol";
import "../src/Curve.sol";
import "../src/Structs.sol";
import "../src/Router.sol";
import "../src/lib/ABDKMath64x64.sol";
import "../src/lib/FullMath.sol";

import "./lib/MockUser.sol";
import "./lib/CheatCodes.sol";
import "./lib/Address.sol";
import "./lib/CurveParams.sol";
import "./utils/Utils.sol";
import "./utils/CuveFlash.sol";

contract FlashloanTest is Test {
    using SafeMath for uint256;

    CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    Utils utils;

    MockUser multisig;
    MockUser flashloaner;
    MockUser[2] public users;

    IERC20Detailed usdc = IERC20Detailed(Mainnet.USDC);
    IERC20Detailed cadc = IERC20Detailed(Mainnet.CADC);
    IERC20Detailed xsgd = IERC20Detailed(Mainnet.XSGD);
    IERC20Detailed euroc = IERC20Detailed(Mainnet.EUROC);

    uint8 constant fxTokenCount = 3;

    IERC20Detailed[] public foreignStables = [
        cadc,
        xsgd, 
        euroc, 
        usdc
    ];

    IOracle usdcOracle = IOracle(Mainnet.CHAINLINK_USDC_USD);
    IOracle cadcOracle = IOracle(Mainnet.CHAINLINK_CAD_USD);
    IOracle xsgdOracle = IOracle(Mainnet.CHAINLINK_SGD_USD);
    IOracle eurocOracle = IOracle(Mainnet.CHAINLINK_EUR_USD);

    IOracle[] public foreignOracles = [
        cadcOracle,
        xsgdOracle,
        eurocOracle,
        usdcOracle
    ];

    int128 public protocolFee = 100;

    AssimilatorFactory assimilatorFactory;
    CurveFactoryV2 curveFactory;
    Router router;
    Curve[fxTokenCount] dfxCurves;
    CurveFlash curveFlash;

    function setUp() public {
        multisig = new MockUser();
        flashloaner = new MockUser();
        utils = new Utils();
        curveFlash = new CurveFlash();

        for (uint8 i = 0; i < users.length; i++) {
            users[i] = new MockUser();
        }

        assimilatorFactory = new AssimilatorFactory();
        
        curveFactory = new CurveFactoryV2(
            protocolFee,
            address(multisig),
            address(assimilatorFactory)
        );

        router = new Router(address(curveFactory));
        
        assimilatorFactory.setCurveFactory(address(curveFactory));
        
        for (uint8 i = 0; i < fxTokenCount; i++) {
            CurveInfo memory curveInfo = CurveInfo(
                string.concat("dfx-", foreignStables[i].symbol()),
                string.concat("dfx-", foreignStables[i].symbol()),
                address(foreignStables[i]),
                address(usdc),
                DefaultCurve.BASE_WEIGHT,
                DefaultCurve.QUOTE_WEIGHT,
                address(foreignOracles[i]),
                foreignStables[i].decimals(),
                address(usdcOracle),
                usdc.decimals()
            );

            dfxCurves[i] = curveFactory.newCurve(curveInfo);
            dfxCurves[i].setParams(
                DefaultCurve.ALPHA,
                DefaultCurve.BETA,
                DefaultCurve.MAX,
                DefaultCurve.EPSILON,
                DefaultCurve.LAMBDA
            );

            dfxCurves[i].turnOffWhitelisting();
        }
        

        uint256 user1TknAmnt = 300_000_000;

        // Mint Foreign Stables
        for (uint8 i = 0; i <= fxTokenCount; i++) {
            uint256 decimals = utils.tenToPowerOf(foreignStables[i].decimals());
            deal(address(foreignStables[i]), address(users[0]), user1TknAmnt.mul(decimals));
        }
        
        cheats.startPrank(address(users[0]));
        for (uint8 i = 0; i < fxTokenCount; i++) {            
            foreignStables[i].approve(address(dfxCurves[i]), type(uint).max);
            foreignStables[i].approve(address(router), type(uint).max);
            usdc.approve(address(dfxCurves[i]), type(uint).max);
        }
        usdc.approve(address(router), type(uint).max);
        cheats.stopPrank();

        cheats.startPrank(address(users[0]));
        for (uint8 i = 0; i < fxTokenCount; i++) {           
            dfxCurves[i].deposit(100_000_000e18, block.timestamp + 60);
        }
        cheats.stopPrank();
    }

    function testFlashloan(uint256 flashAmount, uint24 flashFee) public {
        cheats.assume(flashAmount > 0);
        cheats.assume(flashAmount < 10_000_000);

        uint256 decimals = utils.tenToPowerOf(cadc.decimals());

        deal(Mainnet.CADC, address(curveFlash), 100_000e18);
        deal(Mainnet.USDC, address(curveFlash), 100_000e6);

        uint256 derivative0Before = IERC20(Mainnet.CADC).balanceOf(address(dfxCurves[0]));
        uint256 derivative1Before = IERC20(Mainnet.USDC).balanceOf(address(dfxCurves[0]));

        FlashParams memory flashData = FlashParams({
            token0: address(Mainnet.CADC),
            token1: address(Mainnet.USDC),
            fee: uint24(100),
            amount0: flashAmount.mul(decimals),
            amount1: flashAmount.mul(1e6)
        });

        // TODO insert midway test to see that curve actually had funds to play with
        curveFlash.initFlash(address(dfxCurves[0]), flashData);
        
        uint256 derivative0After = IERC20(Mainnet.CADC).balanceOf(address(dfxCurves[0]));
        uint256 derivative1After = IERC20(Mainnet.USDC).balanceOf(address(dfxCurves[0]));

        uint256 generatedFee0 = FullMath.mulDivRoundingUp(flashData.amount0, flashData.fee, 1e6);
        uint256 generatedFee1 = FullMath.mulDivRoundingUp(flashData.amount1, flashData.fee, 1e6);

        // Should transfer the ownership to multisig tho
        assertEq(generatedFee0, IERC20(Mainnet.CADC).balanceOf(address(this)));
        assertEq(generatedFee1, IERC20(Mainnet.USDC).balanceOf(address(this)));

        assertGe(derivative0After, derivative0Before);
        assertGe(derivative1After, derivative1Before);
    }

    function testFlashloanFeeFail(uint256 flashAmount, uint24 flashFee) public {
        cheats.assume(flashAmount > 0);
        cheats.assume(flashAmount < 10_000_000);

        cheats.assume(flashFee > 0);
        cheats.assume(flashFee < 100);

        uint256 decimals = utils.tenToPowerOf(cadc.decimals());

        deal(Mainnet.CADC, address(curveFlash), 100_000e18);
        deal(Mainnet.USDC, address(curveFlash), 100_000e6);

        uint256 derivative0Before = IERC20(Mainnet.CADC).balanceOf(address(dfxCurves[0]));
        uint256 derivative1Before = IERC20(Mainnet.USDC).balanceOf(address(dfxCurves[0]));

        FlashParams memory flashData = FlashParams({
            token0: address(Mainnet.CADC),
            token1: address(Mainnet.USDC),
            fee: flashFee,
            amount0: flashAmount.mul(decimals),
            amount1: flashAmount.mul(1e6)
        });

        curveFlash.initFlash(address(dfxCurves[0]), flashData);
    }

    // function testFlashloanCurveDepthFail(uint256 flashAmount, uint24 flashFee) public {
    // }
}
