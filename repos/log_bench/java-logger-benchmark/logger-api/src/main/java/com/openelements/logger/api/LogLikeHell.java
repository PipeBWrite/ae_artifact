package com.openelements.logger.api;

import java.util.UUID;

public class LogLikeHell implements Runnable {

    public static final RuntimeException THROWABLE = new RuntimeException("Oh no!");

    // optional message payload to scale bytes/op.
    // Default 0 keeps every message byte-identical to the original benchmark.
    // Precomputed at class init -> zero per-op concatenation cost.
    private static final String PAD =
            "x".repeat(Integer.getInteger("log4j.bench.payload", 0));
    private static final String M0 = "L0, Hello world!" + PAD;
    private static final String M1 = "L1, A quick brown fox jumps over the lazy dog." + PAD;
    private static final String M2 = "L2, Hello world!" + PAD;
    private static final String M3 = "L3, Hello {}!" + PAD;
    private static final String M4 = "L4, Hello {}!" + PAD;
    private static final String M5 = "L5, Hello world!" + PAD;
    private static final String M6 = "L6, Hello world!" + PAD;
    private static final String M7 = "L7, Hello world!" + PAD;
    private static final String M8 = "L8, Hello {}, {}, {}, {}, {}, {}, {}, {}, {}!" + PAD;
    private static final String M9 = "L9, Hello {}, {}, {}, {}, {}, {}, {}, {}, {}!" + PAD;
    private static final String M10 = "L10, Hello world!" + PAD;
    private static final String M11 = "L11, Hello world!" + PAD;
    private static final String M12 = "L12, Hello world!" + PAD;
    private static final String M13 = "L13, Hello {}, {}, {}, {}, {}, {}, {}, {}, {}!" + PAD;

    private final Logger logger;

    public LogLikeHell(Logger logger) {
        this.logger = logger;
    }

    // repeat the 14-message body N times per op (default 1 = original).
    // Scales messages/op without changing per-message shape.
    private static final int REPEAT = Integer.getInteger("log4j.bench.repeat", 1);

    @Override
    public void run() {
        for (int _r = 0; _r < REPEAT; _r++) {
            runOnce();
        }
    }

    private void runOnce() {
        logger.log(M0);
        logger.log(M1);
        logger.log(M2, THROWABLE);
        logger.log(M3, "placeholder");
        logger.log(M4, THROWABLE, "placeholder");
        logger.withMetadata("key", "value").log(M5);
        logger.withMarker("marker").log(M6);
        logger.withMetadata("user-id", UUID.randomUUID().toString())
                .log(M7);
        logger.withMetadata("user-id", UUID.randomUUID().toString())
                .log(M8,
                        1, 2, 3, 4, 5, 6, 7, 8, 9);
        logger.withMetadata("user-id", UUID.randomUUID().toString())
                .log(M9, THROWABLE,
                        1, 2, 3, 4, 5, 6, 7, 8, 9);
        logger.withMetadata("user-id", UUID.randomUUID().toString())
                .withMetadata("key", "value")
                .log(M10);
        logger.withMarker("marker")
                .log(M11);
        logger.withMarker("marker1")
                .withMarker("marker2")
                .log(M12);
        logger.withMetadata("key", "value")
                .withMarker("marker1").withMarker("marker2")
                .log(M13,
                        1, 2, 3, 4, 5, 6, 7, 8, 9);
    }
}
