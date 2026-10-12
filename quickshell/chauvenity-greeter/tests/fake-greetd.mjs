// A greetd to run the greeter against while greetd is not installed: it
// speaks greetd's IPC (a 4-byte native-endian length, then JSON) on the unix
// socket it is given, accepts one password and writes down what it was asked
// to start.
//
//   node fake-greetd.mjs --socket /tmp/greetd.sock --password hunter2 \
//        --log /tmp/greetd.log [--launch-delay 3000]
//
// The log has one JSON object per line, one per request. The password is
// never written to it, only whether it was the right one.
//
// The password "stall" is never answered, for a greetd that hangs.
//
// greetd's rules it keeps to: a session is created before it is answered, a
// refused password ends the session, and start_session needs an accepted one.

import net from "node:net";
import fs from "node:fs";
import os from "node:os";

export function startFakeGreetd({ socket, password = "hunter2", log = null, launchDelay = 0 }) {
    const record = entry => log && fs.appendFileSync(log, JSON.stringify(entry) + "\n");

    function reply(connection, message) {
        const body = Buffer.from(JSON.stringify(message));
        const header = Buffer.alloc(4);
        header[os.endianness() === "LE" ? "writeUInt32LE" : "writeUInt32BE"](body.length);
        connection.write(Buffer.concat([header, body]));
    }

    const error = (description, type = "error") => ({ type: "error", error_type: type, description });

    // One connection is one greeter; "none", "asked" or "accepted".
    function serve(connection) {
        let session = "none";
        let pending = Buffer.alloc(0);

        function handle(request) {
            switch (request.type) {
            case "create_session":
                if (session !== "none")
                    return error("a session is already being created");
                session = "asked";
                record({ type: "create_session", username: request.username });
                return { type: "auth_message", auth_message_type: "secret", auth_message: "Password: " };
            case "post_auth_message_response":
                if (session !== "asked")
                    return error("no question is waiting");
                if (request.response === "stall") {
                    record({ type: "post_auth_message_response", stalled: true });
                    return { type: "none", delay: 3600000 };
                }
                if (request.response === password) {
                    session = "accepted";
                    record({ type: "post_auth_message_response", correct: true });
                    return { type: "success" };
                }
                session = "none";
                record({ type: "post_auth_message_response", correct: false });
                return error("pam_authenticate: AUTH_ERR", "auth_error");
            case "start_session":
                if (session !== "accepted")
                    return error("the session is not authenticated");
                record({ type: "start_session", cmd: request.cmd, env: request.env });
                return { type: "success", delay: launchDelay };
            case "cancel_session":
                session = "none";
                record({ type: "cancel_session" });
                return { type: "success" };
            default:
                return error(`unknown request ${request.type}`);
            }
        }

        connection.on("data", chunk => {
            pending = Buffer.concat([pending, chunk]);
            while (pending.length >= 4) {
                const length = os.endianness() === "LE" ? pending.readUInt32LE(0) : pending.readUInt32BE(0);
                if (pending.length < 4 + length)
                    return;
                const request = JSON.parse(pending.subarray(4, 4 + length).toString());
                pending = pending.subarray(4 + length);
                const { delay = 0, ...response } = handle(request);
                setTimeout(() => reply(connection, response), delay);
            }
        });
        connection.on("error", () => {});
    }

    fs.rmSync(socket, { force: true });
    const server = net.createServer(serve);
    return new Promise(resolve => server.listen(socket, () => resolve(server)));
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const args = process.argv.slice(2);
    const option = (name, fallback) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
    const socket = option("--socket", process.env.GREETD_SOCK);
    if (!socket) {
        console.error("fake-greetd: --socket PATH or GREETD_SOCK");
        process.exit(2);
    }
    await startFakeGreetd({
        socket,
        password: option("--password", "hunter2"),
        log: option("--log", null),
        launchDelay: Number(option("--launch-delay", 0)),
    });
    console.log(`fake-greetd: listening on ${socket}`);
}
