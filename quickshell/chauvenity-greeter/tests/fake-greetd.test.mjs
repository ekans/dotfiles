// The fake greetd keeps to greetd's protocol, so a greeter that works against
// it is not working against a fiction. These speak it as a client would.

import { test } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { startFakeGreetd } from "./fake-greetd.mjs";

async function withGreetd(run) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fake-greetd-"));
    const log = path.join(dir, "log");
    const server = await startFakeGreetd({ socket: path.join(dir, "sock"), password: "right", log });
    const connection = net.connect(path.join(dir, "sock"));
    await new Promise(resolve => connection.once("connect", resolve));
    let pending = Buffer.alloc(0);
    const waiting = [];
    connection.on("data", chunk => {
        pending = Buffer.concat([pending, chunk]);
        while (pending.length >= 4 && pending.length >= 4 + pending.readUInt32LE(0)) {
            const length = pending.readUInt32LE(0);
            waiting.shift()(JSON.parse(pending.subarray(4, 4 + length).toString()));
            pending = pending.subarray(4 + length);
        }
    });
    const ask = request => new Promise(resolve => {
        const body = Buffer.from(JSON.stringify(request));
        const header = Buffer.alloc(4);
        header.writeUInt32LE(body.length);
        waiting.push(resolve);
        connection.write(Buffer.concat([header, body]));
    });
    try {
        await run(ask, () => fs.readFileSync(log, "utf8").trim().split("\n").map(line => JSON.parse(line)));
    } finally {
        connection.destroy();
        server.close();
        fs.rmSync(dir, { recursive: true });
    }
}

test("the right password gets a session started, and the command is written down", async () => {
    await withGreetd(async (ask, log) => {
        assert.deepEqual(await ask({ type: "create_session", username: "ducatore" }),
            { type: "auth_message", auth_message_type: "secret", auth_message: "Password: " });
        assert.deepEqual(await ask({ type: "post_auth_message_response", response: "right" }), { type: "success" });
        assert.deepEqual(await ask({ type: "start_session", cmd: ["niri-session"], env: ["A=b"] }), { type: "success" });
        assert.deepEqual(log(), [
            { type: "create_session", username: "ducatore" },
            { type: "post_auth_message_response", correct: true },
            { type: "start_session", cmd: ["niri-session"], env: ["A=b"] },
        ]);
    });
});

test("a wrong password ends the session; starting one is then refused", async () => {
    await withGreetd(async ask => {
        await ask({ type: "create_session", username: "ducatore" });
        const refused = await ask({ type: "post_auth_message_response", response: "wrong" });
        assert.equal(refused.error_type, "auth_error");
        assert.equal((await ask({ type: "start_session", cmd: ["x"], env: [] })).type, "error");
        assert.equal((await ask({ type: "create_session", username: "ducatore" })).type, "auth_message");
    });
});

test("the password is never in the log", async () => {
    await withGreetd(async (ask, log) => {
        await ask({ type: "create_session", username: "ducatore" });
        await ask({ type: "post_auth_message_response", response: "wrong-secret" });
        assert.ok(!JSON.stringify(log()).includes("wrong-secret"));
    });
});
