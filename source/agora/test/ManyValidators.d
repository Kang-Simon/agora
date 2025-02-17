/*******************************************************************************

    Contains networking tests with a variety of different validator node counts.

    Copyright:
        Copyright (c) 2019-2021 BOSAGORA Foundation
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

module agora.test.ManyValidators;

version (unittest):

import agora.test.Base;

import core.thread;
import core.time;

void manyValidators (size_t validators)
{
    TestConf conf = { outsider_validators : validators - GenesisValidators };
    conf.node.network_discovery_interval = 2.seconds;
    conf.node.retry_delay = 250.msecs;

    auto network = makeTestNetwork!TestAPIManager(conf);
    network.start();
    scope(exit) network.shutdown();
    scope(failure) network.printLogs();
    network.waitForDiscovery();

    // generate 18 blocks, 2 short of the enrollments expiring.
    network.generateBlocks(Height(GenesisValidatorCycle - 2));

    // prepare frozen outputs for the outsider validator to enroll
    network.postAndEnsureTxInPool(network.freezeUTXO(iota(GenesisValidators, GenesisValidators + conf.outsider_validators)));

    // block 19
    network.generateBlocks(Height(GenesisValidatorCycle - 1));

    // make sure outsiders are up to date
    network.expectHeight(iota(GenesisValidators, validators),
        Height(GenesisValidatorCycle - 1));

    // Now we enroll new validators and re-enroll the original validators
    iota(validators).each!(idx => network.enroll(idx));

    // Generate the last block of cycle with Genesis validators
    network.generateBlocks(iota(GenesisValidators),
        Height(GenesisValidatorCycle));

    // make sure outsiders are up to date
    network.expectHeight(iota(GenesisValidators, validators),
        Height(GenesisValidatorCycle));

    // check all validators are enrolled at block 20 by counting active in next block height
    network.clients.enumerate.each!((idx, node) =>
        retryFor(node.countActive(Height(GenesisValidatorCycle + 1)) == validators, 5.seconds,
            format("Node %s has validator count %s. Expected: %s",
                idx, node.countActive(Height(GenesisValidatorCycle + 1)), validators)));

    // Wait for nodes to run a discovery task and update their required peers
    Thread.sleep(3.seconds);
    network.waitForDiscovery();

    // first validated block using all nodes
    network.generateBlocks(iota(validators), Height(GenesisValidatorCycle + 1));
    network.assertSameBlocks(Height(GenesisValidatorCycle + 1));
}

/// 10 nodes
unittest
{
    manyValidators(10);
}

// temporarily disabled until failures are resolved
// see #1145
version (none):
/// 16 nodes
unittest
{
    manyValidators(16);
}

/// 32 nodes
unittest
{
    manyValidators(32);
}
