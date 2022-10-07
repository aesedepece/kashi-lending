const { network } = require("hardhat")
const { expect } = require("chai")
const { createFixture } = require("@sushiswap/hardhat-framework")

let cmd, fixture

const ADDRESSES = {
    // This is actually Polygon
    "hardhat": "0x3806311c7138ddF2bAF2C2093ff3633E5A73AbD4"
}

async function testPairAndExpectDigits(oracle, base, quote, decimals, expectedDigits) {
    const [getDataSuccess, data] = await oracle.getDataParameter(base, quote, decimals)
    expect(getDataSuccess).to.be.true
    await oracle.get(data)
    const [peekSuccess, rate] = await oracle.peek(data)
    expect(peekSuccess).to.be.true
    expect(Math.log10(rate)).to.be.approximately(expectedDigits, 1)
}

describe("Witnet Oracle", function () {
    before(async function () {
        fixture = await createFixture(deployments, this, async (cmd) => {
            const witnetAddress = ADDRESSES[network.name]
            await cmd.deploy("oracle", "WitnetOracle", witnetAddress, ["USD"])
        })
    })

    beforeEach(async function () {
        cmd = await fixture()
    })

    it("Assigns name to Witnet", async function () {
        expect(await this.oracle.name(0)).to.equal("Witnet")
    })

    it("Assigns symbol to WIT", async function () {
        expect(await this.oracle.symbol(0)).to.equal("WIT")
    })

    if (!network.config.forking) {
        console.trace("*** chain forking not available, skipping tests ***")
        return
    }

    it("should return native BTC/USD price with 6 decimals (its native resolution)", async function () {
        await testPairAndExpectDigits(this.oracle, "BTC", "USD", 6, 10)
    })

    it("should return native BTC/USD price with 3 decimals (should trim)", async function () {
        await testPairAndExpectDigits(this.oracle, "BTC", "USD", 3, 7)
    })

    it("should return native BTC/USD price with 9 decimals (should expand)", async function () {
        await testPairAndExpectDigits(this.oracle, "BTC", "USD", 9, 13)
    })

    it("should return routed BTC/ETH price through BTC/USD / ETH/USD with 6 decimals (its native resolution)", async function () {
        await testPairAndExpectDigits(this.oracle, "BTC", "ETH", 6, 7)
    })

    it("should return routed BTC/ETH price through BTC/USD / ETH/USD with 3 decimals (should trim)", async function () {
        await testPairAndExpectDigits(this.oracle, "BTC", "ETH", 3, 4)
    })

    it("should return routed BTC/ETH price through BTC/USD / ETH/USD with 9 decimals (should expand)", async function () {
        await testPairAndExpectDigits(this.oracle, "BTC", "ETH", 9, 10)
    })

    it("should return routed BTC/DAI price through BTC/USD / DAI/USD with 15 decimals (should adjust decimals accordingly)", async function () {
        await testPairAndExpectDigits(this.oracle, "BTC", "DAI", 15, 19)
    })

    it("should fail for made-up assets", async function () {
        const [getDataSuccess, data] = await this.oracle.getDataParameter("XXX", "YYY", 6)
        expect(getDataSuccess).to.be.false
        await expect(this.oracle.get(data)).to.be.revertedWith("WitnetPriceRouter: unsupported currency pair")
    })

    it("should fail for unroutable pairs", async function () {
        const [getDataSuccess, data] = await this.oracle.getDataParameter("BTC", "VSQ", 6)
        expect(getDataSuccess).to.be.false
        await expect(this.oracle.get(data)).to.be.revertedWith("WitnetPriceRouter: unsupported currency pair")
    })
})
