pragma solidity ^0.6.0;

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./cryptoblades.sol";
import "./characters.sol";
import "./weapons.sol";
import "./shields.sol";
import "./Promos.sol";
import "./util.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract Pvpcb is Initializable, AccessControlUpgradeable {

    /*
        Actual pvps reimplementation
        Figured the old contract may have a lot of redundant variables and it's already deployed
        Maybe the pvp interface isn't the way to go
        Either way it's probably fine to lay out the new one in a single file and compare
        The idea is to store all participants and pvp details using an indexed mapping system
        And players get to claim their rewards as a derivative of a pvp completion seed that
            a safe verifiable random source will provide (ideally)
        It may be better to convert the mappings using pvpIndex into a struct
        Need to test gas impact or if stack limits are any different
    */

    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant GAME_ADMIN = keccak256("GAME_ADMIN");

    uint8 public constant STATUS_UNSTARTED = 0;
    uint8 public constant STATUS_STARTED = 1;
    uint8 public constant STATUS_WON = 2;
    uint8 public constant STATUS_LOST = 3;
    uint8 public constant STATUS_PAUSED = 4; // in case of emergency

    // leaving link 0 empty intentionally

    CryptoBlades public game;
    Characters public characters;
    Weapons public weapons;
    Shields public shields;
    Promos public promos;
    IERC20 internal soulToken;

    struct Pvper {
        address owner;
        uint256 charID;
        uint256 wepID;
        uint24 power;
        uint24 traitsCWS;//char trait, wep trait, wep statpattern, unused for now
    }

    uint64 public staminaCost;
    uint64 public durabilityCost;
    int128 public joinCost;
    int128 public rewardWin;
    int128 public rewardLose;
    uint16 public xpReward;
    address public maincomtract;

    uint256 public pvpIndex;
    // all (first) keys are pvpIndex
    mapping(uint256 => uint8) public pvpStatus;
    mapping(uint256 => uint256) public pvpEndTime;
    mapping(uint256 => uint256) public pvpSeed;
    mapping(uint256 => uint8) public pvpBossTrait;
    mapping(uint256 => uint256) public pvpBossPower;
    mapping(uint256 => uint256) public pvpPlayerPower;
    mapping(uint256 => Pvper[]) public pvpParticipants;
    mapping(uint256 => mapping(address => uint256[])) public pvpParticipantIndices;
    mapping(uint256 => mapping(address => bool)) public pvpRewardClaimed;
    mapping(address => uint256) public player;
    mapping(address => uint256) public enemyplayer;
    mapping(address => uint256) public enemyroll;
    mapping(address => uint256) public playerroll;
    mapping(uint256 => mapping(address => uint256)) public winnerstatus;


    // link interface
    // the idea is to avoid littering the contract with variables for each type of reward
    mapping(uint256 => address) public links;

    event PvpStarted(uint256 indexed pvpIndex,
        uint8 bossTrait,
        uint256 bossPower,
        uint256 endTime);
    event PvpJoined(uint256 pvpIndex,
        address indexed user,
        uint256 indexed character,
        uint256 indexed weapon,
        uint256 soulPaid);
    event PvpCompleted(uint256 indexed pvpIndex,
        uint8 outcome,
        uint256 bossRoll,
        uint256 playerRoll);

    // reward specific events for analytics
    event RewardClaimed(uint256 indexed pvpIndex, address indexed user, uint256 characterCount);
    function initialize(address gameContract,address _characters,address _weapons,address _shields,IERC20 _soulToken) public initializer {

        __AccessControl_init_unchained();
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(GAME_ADMIN, msg.sender);

        game = CryptoBlades(gameContract);
        characters = Characters(_characters);
        weapons = Weapons(_weapons);
        shields = Shields(_shields);
        promos = Promos(game.promos());
        soulToken = _soulToken;
        joinCost = ABDKMath64x64.divu(10, 1);// 10 usd skill
        rewardLose = ABDKMath64x64.divu(4, 1);// 4 usd
        rewardWin = ABDKMath64x64.divu(14, 1);// 14 usd
        pvpIndex = 100;
        maincomtract = gameContract;
    }

    modifier restricted() {
        _restricted();
        _;
    }

    function _restricted() internal view {
        require(hasRole(GAME_ADMIN, msg.sender), "Not game admin");
    }

    function doPvp(uint256 bossPower, uint8 bossTrait, uint256 durationMinutes) public restricted {
        require(pvpStatus[pvpIndex] != STATUS_PAUSED, "Pvp paused");

        if(pvpStatus[pvpIndex] == STATUS_STARTED
        && pvpParticipants[pvpIndex].length > 0) {
            completePvp();
        }
        startPvp(bossPower, bossTrait, durationMinutes);
    }

    function startPvp(uint256 bossPower, uint8 bossTrait, uint256 durationMinutes) public restricted {
        pvpStatus[pvpIndex] = STATUS_STARTED;
        pvpBossPower[pvpIndex] = bossPower;
        pvpBossTrait[pvpIndex] = bossTrait;

        uint256 endTime = now + (durationMinutes * 1 minutes);
        pvpEndTime[pvpIndex] = endTime;

        emit PvpStarted(pvpIndex, bossTrait, bossPower, endTime);
    }

    function joinPvp(uint256 characterID, uint256 weaponID, uint256 shieldID) public {
        require(characters.ownerOf(characterID) == msg.sender);
        require(weapons.ownerOf(weaponID) == msg.sender);
        uint256[] memory pvperIndices = pvpParticipantIndices[pvpIndex][msg.sender];
        for(uint i = 0; i < pvperIndices.length; i++) {
            require(pvpParticipants[pvpIndex][pvperIndices[i]].wepID != weaponID,
                "This weapon is already used in the pvp");
            require(pvpParticipants[pvpIndex][pvperIndices[i]].charID != characterID,
                "This character is already participating");
            require(pvpParticipants[pvpIndex][pvperIndices[i]].owner != msg.sender,
                "This address is already participating");
        }
        uint256 power = playerpower(characterID,weaponID,shieldID);
        pvpPlayerPower[pvpIndex] += power;

        //uint8 wepStatPattern = weapons.getStatPattern(weaponID);
        pvpParticipantIndices[pvpIndex][msg.sender].push(pvpParticipants[pvpIndex].length);
        pvpParticipants[pvpIndex].push(Pvper(
            msg.sender,
            characterID,
            weaponID,
            uint24(power),
            0//uint24(charTrait) | (uint24(weaponTrait) << 8) | ((uint24(wepStatPattern)) << 16)//traitCWS
        ));
        player[msg.sender] = 0;
        enemyplayer[msg.sender] = 0;
        enemyroll[msg.sender] = 0;
        playerroll[msg.sender] = 0;



        uint256 joinCostPaid = game.usdToSkill(joinCost);
        IERC20(soulToken).approve(msg.sender, joinCostPaid);
        IERC20(soulToken).transferFrom(msg.sender, address(this), joinCostPaid);
        /*
        if(joinCost > 0) {
            //game.payContractTokenOnly(msg.sender, joinCostPaid);
            game.payContractTokenOnly2(msg.sender, joinCostPaid,soulToken);
        }*/
        if(pvpParticipants[pvpIndex].length == 2)
        {
            completePvpWithSeed(game.randoms().getRandomSeed(msg.sender));
        }

        emit PvpJoined(pvpIndex,
            msg.sender,
            characterID,
            weaponID,
            joinCostPaid);


    }
    function playerpower(uint256 characterID,uint256 weaponID,uint256 shieldID) public view returns(uint256)
    {
        (int128 weaponMultTarget,,
        uint24 weaponBonusPower,
        ) = weapons.getFightData(weaponID, characters.getTrait(characterID));
        (int128 shieldMultTarget,,
        uint24 shieldBonusPower,
        ) = shields.getFightData(shieldID, characters.getTrait(characterID));
        uint256 charpower = game.getPlayerPower(characters.getPower(characterID), weaponMultTarget, weaponBonusPower);
        charpower += game.getPlayerPower(characters.getPower(characterID), shieldMultTarget, shieldBonusPower);

        return charpower;
    }

    function setPvpStatus(uint256 index, uint8 status) public restricted {
        // only use if absolutely necessary
        pvpStatus[index] = status;
    }

    function completePvp() public restricted {
        completePvpWithSeed(game.randoms().getRandomSeed(msg.sender));
    }
    function pvpworking() internal
    {
        uint256 player1Roll;
        uint256 player2Roll;
        if(pvpParticipants[pvpIndex][0].power > pvpParticipants[pvpIndex][1].power+(pvpParticipants[pvpIndex][1].power*20/100))
        {
            player1Roll = uint256(RandomUtil.randomSeededMinMax(pvpParticipants[pvpIndex][1].power+(pvpParticipants[pvpIndex][1].power*20/100)-(pvpParticipants[pvpIndex][1].power+(pvpParticipants[pvpIndex][1].power*20/100)*70/100), pvpParticipants[pvpIndex][1].power+(pvpParticipants[pvpIndex][1].power*20/100)+(pvpParticipants[pvpIndex][1].power+(pvpParticipants[pvpIndex][1].power*20/100)*70/100),RandomUtil.combineSeeds(game.randoms().getRandomSeed(msg.sender), game.randoms().getRandomSeed(msg.sender))));
            player2Roll = uint256(RandomUtil.randomSeededMinMax(pvpParticipants[pvpIndex][1].power-(pvpParticipants[pvpIndex][1].power*70/100), pvpParticipants[pvpIndex][1].power+(pvpParticipants[pvpIndex][1].power*70/100),RandomUtil.combineSeeds(game.randoms().getRandomSeed(msg.sender), game.randoms().getRandomSeed(msg.sender))));
            player[pvpParticipants[pvpIndex][0].owner] = pvpParticipants[pvpIndex][1].power+(pvpParticipants[pvpIndex][1].power*20/100);
            player[pvpParticipants[pvpIndex][1].owner] = pvpParticipants[pvpIndex][1].power;
            enemyplayer[pvpParticipants[pvpIndex][0].owner] = pvpParticipants[pvpIndex][1].power;
            enemyplayer[pvpParticipants[pvpIndex][1].owner] = pvpParticipants[pvpIndex][1].power+(pvpParticipants[pvpIndex][1].power*20/100);
        }
        else  if(pvpParticipants[pvpIndex][1].power > pvpParticipants[pvpIndex][0].power+(pvpParticipants[pvpIndex][0].power*20/100))
        {
            player2Roll = uint256(RandomUtil.randomSeededMinMax(pvpParticipants[pvpIndex][0].power+(pvpParticipants[pvpIndex][0].power*20/100)-(pvpParticipants[pvpIndex][0].power+(pvpParticipants[pvpIndex][0].power*20/100)*70/100), pvpParticipants[pvpIndex][0].power+(pvpParticipants[pvpIndex][0].power*20/100)+(pvpParticipants[pvpIndex][0].power+(pvpParticipants[pvpIndex][0].power*20/100)*70/100),RandomUtil.combineSeeds(game.randoms().getRandomSeed(msg.sender), game.randoms().getRandomSeed(msg.sender))));
            player1Roll = uint256(RandomUtil.randomSeededMinMax(pvpParticipants[pvpIndex][0].power-(pvpParticipants[pvpIndex][0].power*70/100), pvpParticipants[pvpIndex][0].power+(pvpParticipants[pvpIndex][0].power*70/100),RandomUtil.combineSeeds(game.randoms().getRandomSeed(msg.sender), game.randoms().getRandomSeed(msg.sender))));
            player[pvpParticipants[pvpIndex][1].owner] = pvpParticipants[pvpIndex][0].power+(pvpParticipants[pvpIndex][0].power*20/100);
            player[pvpParticipants[pvpIndex][0].owner] = pvpParticipants[pvpIndex][0].power;
            enemyplayer[pvpParticipants[pvpIndex][1].owner] = pvpParticipants[pvpIndex][0].power;
            enemyplayer[pvpParticipants[pvpIndex][0].owner] = pvpParticipants[pvpIndex][0].power+(pvpParticipants[pvpIndex][0].power*20/100);
        }
        else
        {
            player1Roll = uint256(RandomUtil.randomSeededMinMax(pvpParticipants[pvpIndex][0].power-(pvpParticipants[pvpIndex][0].power*70/100), pvpParticipants[pvpIndex][0].power+(pvpParticipants[pvpIndex][0].power*70/100),RandomUtil.combineSeeds(game.randoms().getRandomSeed(msg.sender), game.randoms().getRandomSeed(msg.sender))));
            player2Roll = uint256(RandomUtil.randomSeededMinMax(pvpParticipants[pvpIndex][1].power-(pvpParticipants[pvpIndex][1].power*70/100), pvpParticipants[pvpIndex][1].power+(pvpParticipants[pvpIndex][1].power*70/100),RandomUtil.combineSeeds(game.randoms().getRandomSeed(msg.sender), game.randoms().getRandomSeed(msg.sender))));
            player[pvpParticipants[pvpIndex][0].owner] = pvpParticipants[pvpIndex][0].power;
            player[pvpParticipants[pvpIndex][1].owner] = pvpParticipants[pvpIndex][1].power;
            enemyplayer[pvpParticipants[pvpIndex][0].owner] = pvpParticipants[pvpIndex][1].power;
            enemyplayer[pvpParticipants[pvpIndex][1].owner] = pvpParticipants[pvpIndex][0].power;
        }
        enemyroll[pvpParticipants[pvpIndex][0].owner] = player2Roll;
        enemyroll[pvpParticipants[pvpIndex][1].owner] = player1Roll;
        playerroll[pvpParticipants[pvpIndex][0].owner] = player1Roll;
        playerroll[pvpParticipants[pvpIndex][1].owner] = player2Roll;

        if(player1Roll > player2Roll)
        {
            winnerstatus[pvpIndex][pvpParticipants[pvpIndex][0].owner] = 1;
            winnerstatus[pvpIndex][pvpParticipants[pvpIndex][1].owner] = 2;
        }
        else if(player1Roll < player2Roll)
        {
            winnerstatus[pvpIndex][pvpParticipants[pvpIndex][0].owner] = 2;
            winnerstatus[pvpIndex][pvpParticipants[pvpIndex][1].owner] = 1;
        }
        else
        {
            winnerstatus[pvpIndex][pvpParticipants[pvpIndex][0].owner] = 2;
            winnerstatus[pvpIndex][pvpParticipants[pvpIndex][1].owner] = 2;
        }

    }

    function completePvpWithSeed(uint256 seed) internal {

        pvpSeed[pvpIndex] = seed;
        pvpEndTime[pvpIndex] = now;
        pvpworking();

        uint256 bossPower = pvpBossPower[pvpIndex];
        // we could also not include bossPower in the roll to have slightly higher chances of failure
        // with bosspower added to roll ceiling the likelyhood of a win is: playerPower / bossPower
        uint256 roll = RandomUtil.randomSeededMinMax(0,pvpPlayerPower[pvpIndex]+bossPower, seed);
        uint8 outcome = STATUS_WON;
        pvpStatus[pvpIndex] = outcome;

        emit PvpCompleted(pvpIndex, outcome, bossPower, roll);
        pvpIndex++;
        //pvpStatus[pvpIndex] = STATUS_UNSTARTED;
        //doPvp(1,0,999999999);
    }

    function unpackFightData(uint96 playerData)
        public pure returns (uint8 charTrait, uint24 basePowerLevel, uint64 timestamp) {

        charTrait = uint8(playerData & 0xFF);
        basePowerLevel = uint24((playerData >> 8) & 0xFFFFFF);
        timestamp = uint64((playerData >> 32) & 0xFFFFFFFFFFFFFFFF);
    }

    function getPlayerPower(
        uint24 basePower,
        int128 weaponMultiplier,
        uint24 bonusPower
    ) public pure returns(uint24) {
        return uint24(weaponMultiplier.mulu(basePower) + bonusPower);
    }

    function isTraitEffectiveAgainst(uint8 attacker, uint8 defender) public pure returns (bool) {
        return (((attacker + 1) % 4) == defender); // Thanks to Tourist
    }

    function getPlayerFinalPower(uint24 playerPower, uint8 charTrait, uint8 bossTrait) public pure returns(uint24) {
        if(isTraitEffectiveAgainst(charTrait, bossTrait))
            return uint24(ABDKMath64x64.divu(1075,1000).mulu(uint256(playerPower)));
        return playerPower;
    }
    function claimReward(uint256 claimPvpIndex) public {

        require(pvpRewardClaimed[claimPvpIndex][msg.sender] == false, "Already claimed");


        uint256 soulrewardWin = game.usdToSkill(rewardWin);
        uint256 soulrewardLose = game.usdToSkill(rewardLose);

        if(winnerstatus[claimPvpIndex][msg.sender] == 1)
        {
            soulToken.safeTransfer(msg.sender, soulrewardWin);
            //game.sendToken(msg.sender, soulrewardWin,soulToken);
            //soulToken.safeTransferFrom(maincomtract, msg.sender, soulrewardWin);
        }
        else if (winnerstatus[claimPvpIndex][msg.sender] == 2)
        {
            soulToken.safeTransfer(msg.sender, soulrewardLose);
            //game.sendToken(msg.sender, soulrewardLose,soulToken);
            //soulToken.safeTransferFrom(maincomtract, msg.sender, soulrewardLose);
        }

        uint256[] memory pvperIndices = pvpParticipantIndices[claimPvpIndex][msg.sender];

        pvpRewardClaimed[claimPvpIndex][msg.sender] = true;
        emit RewardClaimed(claimPvpIndex, msg.sender, pvperIndices.length);
    }
    /*
    function claimReward(uint256 claimPvpIndex) public {
        // NOTE: this function is stack limited
        //claimPvpIndex can act as a version integer if future rewards change
        bool victory = pvpStatus[claimPvpIndex] == STATUS_WON;
        require(victory || pvpStatus[claimPvpIndex] == STATUS_LOST, "Pvp not over");
        require(pvpRewardClaimed[claimPvpIndex][msg.sender] == false, "Already claimed");

        uint256[] memory pvperIndices = pvpParticipantIndices[claimPvpIndex][msg.sender];
        require(pvperIndices.length > 0, "None of your characters participated");

        uint256 earlyBonusCutoff = pvpParticipants[claimPvpIndex].length/2+1; // first half of players
        // we grab pvper info (power) and give out xp and pvp stats
        for(uint i = 0; i < pvperIndices.length; i++) {
            uint256 pvperIndex = pvperIndices[i];
            Pvper memory pvper = pvpParticipants[claimPvpIndex][pvperIndex];
            int128 earlyMultiplier = ABDKMath64x64.fromUInt(1).add(
                pvperIndex < earlyBonusCutoff ?
                    ABDKMath64x64.divu(1,10).mul( // early bonus, 10%
                        (earlyBonusCutoff-pvperIndex).divu(earlyBonusCutoff)
                    )
                    : ABDKMath64x64.fromUInt(0)
            );
            if(victory) {
                distributeRewards(
                    claimPvpIndex,
                    pvperIndex,
                    ABDKMath64x64.divu(earlyMultiplier.mulu(pvper.power),
                        pvpPlayerPower[claimPvpIndex]/pvpParticipants[claimPvpIndex].length)
                );
            }
            characters.processPvpParticipation(pvper.charID, victory, uint16(earlyMultiplier.mulu(xpReward)));
        }

        pvpRewardClaimed[claimPvpIndex][msg.sender] = true;
        emit RewardClaimed(claimPvpIndex, msg.sender, pvperIndices.length);
    }
    */
/*
    function claimReward(uint256 claimPvpIndex) public {
        //claimPvpIndex can act as a version integer if future rewards change
        //bool victory = pvpStatus[claimPvpIndex] == STATUS_WON;
        //require(victory || pvpStatus[claimPvpIndex] == STATUS_LOST, "Pvp not over");
        require(pvpRewardClaimed[claimPvpIndex][msg.sender] == false, "Already claimed");

        uint256[] memory pvperIndices = pvpParticipantIndices[claimPvpIndex][msg.sender];
        //require(pvperIndices.length > 0, "None of your characters participated");
        uint256 soulrewardWin = game.usdToSoul(rewardWin);
        uint256 soulrewardLose = game.usdToSoul(rewardLose);

        if(winnerstatus[msg.sender] == 1)
        {
            soulToken.safeTransfer(msg.sender, soulrewardWin);
        }
        else if (winnerstatus[msg.sender] == 2)
        {
            soulToken.safeTransfer(msg.sender, soulrewardLose);
        }
        pvpRewardClaimed[claimPvpIndex][msg.sender] = true;
        checkjoin[msg.sender] = false;
        emit RewardClaimed(claimPvpIndex, msg.sender, pvperIndices.length);
    }/*
    function distributeRewards(
        uint256 claimPvpIndex,
        uint256 pvperIndex,
        int128 comparedToAverage
    ) private {
        // at most 2 types of rewards
        // common: Lb dust, 1-3 star junk, 3 star wep
        // rare: 4-5b dust, 4-5 star wep, 4-5 star junk, keybox
        // chances are a bit generous compared to weapon mints because stamina cost equals lost skill
        // That being said these rates stink if the oracle is 3x lower than real value.
        uint256 seed = uint256(keccak256(abi.encodePacked(pvpSeed[claimPvpIndex], pvperIndex, uint256(msg.sender))));

        uint256 commonRoll = RandomUtil.randomSeededMinMax(1, 15 + comparedToAverage.mulu(85), seed);
        if(commonRoll > 20) { // Expected: ~75% (at least 25% at bottom, 90+% past 65% power)
            uint mod = seed % 10;
            if(mod < 2) { // 1 star junk, 2 out of 10 (20%)
                distributeJunk(msg.sender, claimPvpIndex, 0);
            }
            else if(mod < 4) { // 2 star junk, 2 out of 10 (20%)
                distributeJunk(msg.sender, claimPvpIndex, 1);
            }
            else if(mod < 6) { // 2 star weapon, 2 out of 10 (20%)
                distributeWeapon(msg.sender, claimPvpIndex, seed, 1);
            }
            else if(mod == 6) { // 3 star junk, 1 out of 10 (10%)
                distributeJunk(msg.sender, claimPvpIndex, 2);
            }
            else if(mod == 7) { // 1x LB Dust, 1 out of 10 (10%)
                distributeLBDust(msg.sender, claimPvpIndex, 1);
            }
            else if(mod == 8) { // 2x LB Dust, 1 out of 10 (10%)
                distributeLBDust(msg.sender, claimPvpIndex, 2);
            }
            else { // 3 star weapon, 1 out of 10 (10%)
                distributeWeapon(msg.sender, claimPvpIndex, seed, 2);
            }
        }

        uint256 rareRoll = RandomUtil.randomSeededMinMax(1, 950 + comparedToAverage.mulu(50), seed + 1);
        if(rareRoll > 950) { // Expected: ~5% (0.72% at bottom, 15% at top, 8.43% middle)
            uint mod = (seed / 10) % 20;
            if(mod < 8) { // key box, 8 out of 20 (40%)
                distributeKeyBox(msg.sender, claimPvpIndex);
            }
            else if(mod == 8) { // 5 star sword, 1 out of 20 (5%)
                distributeWeapon(msg.sender, claimPvpIndex, seed, 4);
            }
            else if(mod == 9) { // 5 star junk, 1 out of 20 (5%)
                distributeJunk(msg.sender, claimPvpIndex, 4);
            }
            else if(mod < 14) { // 4 star sword, 4 out of 20 (20%)
                distributeWeapon(msg.sender, claimPvpIndex, seed, 3);
            }
            else if(mod == 14) { // 1x 4B Dust, 1 out of 20 (5%)
                distribute4BDust(msg.sender, claimPvpIndex, 1);
            }
            else if(mod == 15) { // 1x 5B Dust, 1 out of 20 (5%)
                distribute5BDust(msg.sender, claimPvpIndex, 1);
            }
            else { // 4 star junk, 4 out of 20 (20%)
                distributeJunk(msg.sender, claimPvpIndex, 3);
            }
        }
    }

    function distributeKeyBox(address claimant, uint256 claimPvpIndex) private {
        uint tokenID = KeyLootbox(links[LINK_KEYBOX]).mint(claimant);
        emit RewardedKeyBox(claimPvpIndex, claimant, tokenID);
    }

    function distributeJunk(address claimant, uint256 claimPvpIndex, uint8 stars) private {
        uint tokenID = Junk(links[LINK_JUNK]).mint(claimant, stars);
        emit RewardedJunk(claimPvpIndex, claimant, stars, tokenID);
    }

    function distributeWeapon(address claimant, uint256 claimPvpIndex, uint256 seed, uint8 stars) private {
        uint tokenID = weapons.mintWeaponWithStars(claimant, stars, seed / 100);
        emit RewardedWeapon(claimPvpIndex, claimant, stars, tokenID);
    }

    function distributeLBDust(address claimant, uint256 claimPvpIndex, uint32 amount) private {
        weapons.incrementDustSupplies(claimant, amount, 0, 0);
        emit RewardedDustLB(claimPvpIndex, claimant, amount);
    }

    function distribute4BDust(address claimant, uint256 claimPvpIndex, uint32 amount) private {
        weapons.incrementDustSupplies(claimant, 0, amount, 0);
        emit RewardedDust4B(claimPvpIndex, claimant, amount);
    }

    function distribute5BDust(address claimant, uint256 claimPvpIndex, uint32 amount) private {
        weapons.incrementDustSupplies(claimant, 0, 0, amount);
        emit RewardedDust5B(claimPvpIndex, claimant, amount);
    }
    */

    function registerLink(address addr, uint256 index) public restricted {
        links[index] = addr;
    }

    function setStaminaPointCost(uint8 points) public restricted {
        staminaCost = points;
    }

    function setDurabilityPointCost(uint8 points) public restricted {
        durabilityCost = points;
    }

    function setJoinCostInCents(uint256 cents) public restricted {
        joinCost = ABDKMath64x64.divu(cents, 100);
    }

    function getJoinCostInSoul() public view returns(uint256) {
        return game.usdToSkill(joinCost);
    }

    function setXpReward(uint16 xp) public restricted {
        xpReward = xp;
    }

    function getPvpStatus(uint256 index) public view returns(uint8) {
        return pvpStatus[index];
    }

    function getPvpEndTime(uint256 index) public view returns(uint256) {
        return pvpEndTime[index];
    }

    function getPvpBossTrait(uint256 index) public view returns(uint8) {
        return pvpBossTrait[index];
    }

    function getPvpBossPower(uint256 index) public view returns(uint256) {
        return pvpBossPower[index];
    }

    function getPvpPlayerPower(uint256 index) public view returns(uint256) {
        return pvpPlayerPower[index];
    }

    function getPvpParticipantCount(uint256 index) public view returns(uint256) {
        return pvpParticipants[index].length;
    }

    function getEligibleRewardIndexes(uint256 startIndex, uint256 endIndex) public view returns(uint256[] memory) {
        uint indexCount = 0;
        for(uint i = startIndex; i <= endIndex; i++) {
            if(isEligibleForReward(i)) {
                indexCount++;
            }
        }
        uint256[] memory result = new uint256[](indexCount);
        uint currentIndex = 0;
        for(uint i = startIndex; i <= endIndex; i++) {
            if(isEligibleForReward(i)) {
                result[currentIndex++] = i;
            }
        }
        return result;
    }

    function isEligibleForReward(uint256 index) public view returns(bool) {
        return pvpParticipantIndices[index][msg.sender].length > 0
            && pvpRewardClaimed[index][msg.sender] == false
            && (pvpStatus[index] == STATUS_WON || pvpStatus[index] == STATUS_LOST);
    }

    function getParticipatingCharacters() public view returns(uint256[] memory) {
        uint256[] memory indices = pvpParticipantIndices[pvpIndex][msg.sender];
        uint256[] memory chars = new uint256[](indices.length);
        for(uint i = 0; i < indices.length; i++) {
            chars[i] = pvpParticipants[pvpIndex][i].charID;
        }
        return chars;
    }

    function getParticipatingWeapons() public view returns(uint256[] memory) {
        uint256[] memory indices = pvpParticipantIndices[pvpIndex][msg.sender];
        uint256[] memory weps = new uint256[](indices.length);
        for(uint i = 0; i < indices.length; i++) {
            weps[i] = pvpParticipants[pvpIndex][i].wepID;
        }
        return weps;
    }

    function getAccountsPvperIndexes(uint256 index) public view returns(uint256[] memory){
        return pvpParticipantIndices[index][msg.sender];
    }

    function getAccountsPower(uint256 index) public view returns(uint256) {
        uint256 totalAccountPower = 0;
        uint256[] memory pvperIndexes = getAccountsPvperIndexes(index);
        for(uint256 i = 0; i < pvperIndexes.length; i++) {
            totalAccountPower += pvpParticipants[index][pvperIndexes[i]].power;
        }
        return totalAccountPower;
    }

    function canJoinPvp(uint256 characterID, uint256 weaponID) public view returns(bool) {

        if(characters.getStaminaPoints(characterID) == 0
        || weapons.getDurabilityPoints(weaponID) == 0
        || pvpStatus[pvpIndex] != STATUS_STARTED
        || pvpEndTime[pvpIndex] <= now)
            return false;

        uint256[] memory pvperIndices = pvpParticipantIndices[pvpIndex][msg.sender];
        for(uint i = 0; i < pvperIndices.length; i++) {
            if(pvpParticipants[pvpIndex][pvperIndices[i]].wepID != weaponID
            || pvpParticipants[pvpIndex][pvperIndices[i]].charID != characterID) {
                return false;
            }
        }

        return true;
    }

    function getLinkAddress(uint256 linkIndex) public view returns (address) {
        return links[linkIndex];
    }

    function getPvpData() public view returns(
        uint256 indexcb, uint256 endTimecb, uint256 pvperCountcb, uint256 playerPowercb,
        uint8 statuscb, uint256 joinSoulcb, uint256 accountPowercb, uint256 playercharcb, uint256 enemycharcb,uint256 winstatuscb,uint256 enemyrollshowcb
        ,uint256 playerrollshowcb
    ) {
        uint256 winindex =pvpIndex-1;
        indexcb = pvpIndex;
        endTimecb = pvpEndTime[pvpIndex];
        pvperCountcb = getPvpParticipantCount(pvpIndex);
        playerPowercb = getPvpPlayerPower(pvpIndex);
        statuscb = getPvpStatus(pvpIndex);
        joinSoulcb = getJoinCostInSoul();
        accountPowercb = getAccountsPower(pvpIndex);
        playercharcb = player[msg.sender];
        enemycharcb = enemyplayer[msg.sender];
        winstatuscb = winnerstatus[winindex][msg.sender];
        enemyrollshowcb=enemyroll[msg.sender];
        playerrollshowcb=playerroll[msg.sender];
    }
}
