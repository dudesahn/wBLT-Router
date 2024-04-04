import pytest
from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
from eth_abi import encode_single
import requests


@pytest.fixture(scope="function", autouse=True)
def isolate(fn_isolation):
    pass


# set this for if we want to use tenderly or not; mostly helpful because with brownie.reverts fails in tenderly forks.
# for this repo, especially helper with the long swap router test
use_tenderly = False

# use this to set what chain we use. 1 for ETH, 250 for fantom, 10 optimism, 42161 arbitrum, 8453 base
chain_used = 8453


@pytest.fixture(scope="session")
def tests_using_tenderly():
    yes_or_no = use_tenderly
    yield yes_or_no


# useful because it doesn't crash when sometimes ganache does, "works" in coverage testing but then doesn't actually write any data lol
# if we're using anvil, make sure to use the correct network (base-anvil-fork vs base-dev-fork)
# tbh anvil seems slower than ganache, so not worth it here w/ fuzzing
use_anvil = True


@pytest.fixture(scope="session")
def tests_using_anvil():
    yes_or_no = use_anvil
    yield yes_or_no


@pytest.fixture(scope="session", autouse=use_anvil)
def fun_with_anvil(web3):
    web3.manager.request_blocking("anvil_setNextBlockBaseFeePerGas", ["0x0"])


################################################## TENDERLY DEBUGGING ##################################################

# change autouse to True if we want to use this fork to help debug tests
@pytest.fixture(scope="session", autouse=use_tenderly)
def tenderly_fork(web3, chain):
    import requests
    import os

    # Get env variables
    TENDERLY_ACCESS_KEY = os.environ.get("TENDERLY_ACCESS_KEY")
    TENDERLY_USER = os.environ.get("TENDERLY_USER")
    TENDERLY_PROJECT = os.environ.get("TENDERLY_PROJECT")

    # Construct request
    url = f"https://api.tenderly.co/api/v1/account/{TENDERLY_USER}/project/{TENDERLY_PROJECT}/fork"
    headers = {"X-Access-Key": str(TENDERLY_ACCESS_KEY)}
    data = {
        "network_id": str(chain.id),
    }

    # Post request
    response = requests.post(url, json=data, headers=headers)

    # Parse response
    fork_id = response.json()["simulation_fork"]["id"]

    # Set provider to your new Tenderly fork
    fork_rpc_url = f"https://rpc.tenderly.co/fork/{fork_id}"
    tenderly_provider = web3.HTTPProvider(fork_rpc_url, {"timeout": 600})
    web3.provider = tenderly_provider
    print(
        f"https://dashboard.tenderly.co/{TENDERLY_USER}/{TENDERLY_PROJECT}/fork/{fork_id}"
    )


################################################ UPDATE THINGS BELOW HERE ################################################


@pytest.fixture(scope="session")
def gov():  # BMX multisig 0xE02Fb5C70aF32F80Aa7F9E8775FE7F12550348ec
    yield accounts.at("0xE02Fb5C70aF32F80Aa7F9E8775FE7F12550348ec", force=True)


@pytest.fixture(
    params=[
        True,
        False,
    ],
    ids=["receive_underlying", "receive_weth"],
    scope="function",
)
def receive_underlying(request):
    yield request.param


@pytest.fixture(
    params=[
        True,
        False,
    ],
    ids=["round_up", "round_down"],
    scope="function",
)
def round_up(request):
    yield request.param


@pytest.fixture(
    params=[
        True,
        False,
    ],
    ids=["yes_test_swap", "no_test_swap"],
    scope="function",
)
def test_swap(request):
    yield request.param


# use these for our BLT router testing
@pytest.fixture(scope="function")
def router(wBLTRouter, screamsh):
    router = screamsh.deploy(wBLTRouter)
    # router = Contract("0x70FfF9B84788566065f1dFD8968Fb72F798b9aE5")  # v22, testing
    yield router


@pytest.fixture(scope="session")
def screamsh():
    yield accounts.at("0x89955a99552F11487FFdc054a6875DF9446B2902", force=True)


@pytest.fixture(scope="session")
def w_blt():
    yield Contract("0x4E74D4Db6c0726ccded4656d0BCE448876BB4C7A")


@pytest.fixture(scope="session")
def gauge():
    yield Contract("0x1F7B5E65c09dF12742255BB8Fe26958f4B52F9bb")


@pytest.fixture(scope="session")
def weth():
    yield Contract("0x4200000000000000000000000000000000000006")


@pytest.fixture(scope="session")
def bmx():
    yield Contract("0x548f93779fBC992010C07467cBaf329DD5F059B7")


@pytest.fixture(scope="session")
def factory():
    yield "0xe21Aac7F113Bd5DC2389e4d8a8db854a87fD6951"


@pytest.fixture(scope="session")
def obmx():
    yield Contract("0x3Ff7AB26F2dfD482C40bDaDfC0e88D01BFf79713")


@pytest.fixture(scope="session")
def usdc():
    yield Contract("0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA")


@pytest.fixture(scope="session")
def weth_whale():
    yield accounts.at("0xB4885Bc63399BF5518b994c1d0C153334Ee579D0", force=True)


@pytest.fixture(scope="session")
def wblt_whale():
    yield accounts.at("0x0000000000A6F0986c92cf1EC4d2e77aFBE1466D", force=True)


@pytest.fixture(scope="session")
def bmx_whale():
    yield accounts.at("0x37fda9Da0f51dF81a5B316C9Ab8410f9F8175F5b", force=True)
