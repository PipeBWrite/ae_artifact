package com.openelements.logger.benchmarks;

import static com.openelements.logger.api.BenchmarkConstants.FORK_COUNT;
import static com.openelements.logger.api.BenchmarkConstants.MEASUREMENT_ITERATIONS;
import static com.openelements.logger.api.BenchmarkConstants.MEASUREMENT_TIME_IN_SECONDS_PER_ITERATION;
import static com.openelements.logger.api.BenchmarkConstants.PARALLEL_THREAD_COUNT;
import static com.openelements.logger.api.BenchmarkConstants.WARMUP_ITERATIONS;
import static com.openelements.logger.api.BenchmarkConstants.WARMUP_TIME_IN_SECONDS_PER_ITERATION;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import org.apache.logging.log4j.Level;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Marker;
import org.apache.logging.log4j.MarkerManager;
import org.apache.logging.log4j.ThreadContext;
import org.apache.logging.log4j.core.LoggerContext;
import org.apache.logging.log4j.core.config.Configurator;
import org.apache.logging.log4j.core.config.builder.api.AppenderComponentBuilder;
import org.apache.logging.log4j.core.config.builder.api.ConfigurationBuilder;
import org.apache.logging.log4j.core.config.builder.api.ConfigurationBuilderFactory;
import org.apache.logging.log4j.core.config.builder.impl.BuiltConfiguration;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Fork;
import org.openjdk.jmh.annotations.Measurement;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.Param;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.annotations.TearDown;
import org.openjdk.jmh.annotations.Threads;
import org.openjdk.jmh.annotations.Warmup;

/**
 * Write-path-dominant log4j2 throughput workload.
 *
 * Designed to exercise the kernel buffered-write path rather than java-side
 * rendering:
 *  - one PRIVATE logger + File appender + file PER THREAD, so writers run in
 *    parallel with no appender-lock serialization,
 *  - cached logger per thread (no per-call LogManager lookup),
 *  - immediateFlush on by default (one write syscall per event),
 *  - buffered File appender size is configurable
 *    (-Dlog4j.bench.bufferSize / .bufferedIO),
 *  - payload knobs to anchor each workload to a target absolute throughput
 *    (-Dlog4j.bench.payload / .heavy.payload / .complex.payload).
 */
@State(Scope.Benchmark)
public class Log4JThroughputBenchmark {

    private static final String LOG_DIR = System.getProperty("log.output.dir", "target");
    private static final int PAYLOAD = Integer.getInteger("log4j.bench.payload", 1024);
    private static final int NLOGGERS = Integer.getInteger("log4j.bench.loggers", 16);
    private static final String BUFFERED_IO = System.getProperty("log4j.bench.bufferedIO");
    private static final Integer BUFFER_SIZE = Integer.getInteger("log4j.bench.bufferSize");
    private static final boolean IMMEDIATE_FLUSH =
            Boolean.parseBoolean(System.getProperty("log4j.bench.immediateFlush", "true"));
    private static final String MSG = "y".repeat(Math.max(1, PAYLOAD));

    @Param({"FILE"})
    public String loggingType;

    @Setup(org.openjdk.jmh.annotations.Level.Trial)
    public void init() throws Exception {
        Configurator.shutdown((LoggerContext) LogManager.getContext(false));
        for (int i = 0; i < NLOGGERS; i++) {
            Files.deleteIfExists(Path.of(LOG_DIR, "tlog-" + i + ".log"));
        }

        ConfigurationBuilder<BuiltConfiguration> b =
                ConfigurationBuilderFactory.newConfigurationBuilder();
        b.setStatusLevel(Level.ERROR);
        b.setConfigurationName("tputConfig");
        for (int i = 0; i < NLOGGERS; i++) {
            AppenderComponentBuilder app = b.newAppender("file" + i, "File")
                    .addAttribute("fileName", LOG_DIR + "/tlog-" + i + ".log")
                    .addAttribute("append", false)
                    .addAttribute("immediateFlush", IMMEDIATE_FLUSH)
                    .add(b.newLayout("PatternLayout").addAttribute("pattern", "%m%n"));
            if (BUFFERED_IO != null) {
                app.addAttribute("bufferedIO", Boolean.parseBoolean(BUFFERED_IO));
            }
            if (BUFFER_SIZE != null) {
                app.addAttribute("bufferSize", BUFFER_SIZE);
            }
            b.add(app);
            b.add(b.newLogger("tlog." + i, Level.INFO)
                    .add(b.newAppenderRef("file" + i))
                    .addAttribute("additivity", false));
        }
        b.add(b.newRootLogger(Level.ERROR));
        Configurator.initialize(b.build());
    }

    @TearDown(org.openjdk.jmh.annotations.Level.Trial)
    public void close() {
        Configurator.shutdown((LoggerContext) LogManager.getContext(false));
    }

    @State(Scope.Thread)
    public static class PerThread {
        private static final AtomicInteger CTR = new AtomicInteger();
        org.apache.logging.log4j.Logger logger;

        @Setup(org.openjdk.jmh.annotations.Level.Trial)
        public void setup(Log4JThroughputBenchmark bench) {
            // bench parameter forces the Benchmark-scope init() to run first.
            logger = LogManager.getLogger("tlog." + (CTR.getAndIncrement() % NLOGGERS));
        }
    }

    @Benchmark
    @Fork(FORK_COUNT)
    @Threads(PARALLEL_THREAD_COUNT)
    @BenchmarkMode(Mode.Throughput)
    @Warmup(iterations = WARMUP_ITERATIONS, time = WARMUP_TIME_IN_SECONDS_PER_ITERATION)
    @Measurement(iterations = MEASUREMENT_ITERATIONS, time = MEASUREMENT_TIME_IN_SECONDS_PER_ITERATION)
    public void logBytes(PerThread t) {
        t.logger.info(MSG);
    }

    // heavy & complex workloads on the same lock-free per-thread appender.
    // Each message is padded to anchor the run to a target absolute throughput.
    private static final int HEAVY_PAYLOAD = Integer.getInteger("log4j.bench.heavy.payload", 4096);
    private static final int COMPLEX_PAYLOAD = Integer.getInteger("log4j.bench.complex.payload", 5120);
    private static final String HPAD = "h".repeat(Math.max(0, HEAVY_PAYLOAD));
    private static final String CPAD = "c".repeat(Math.max(0, COMPLEX_PAYLOAD));
    private static final String H0 = "L0, Hello world!" + HPAD;
    private static final String H1 = "L1, A quick brown fox jumps over the lazy dog." + HPAD;
    private static final String H2 = "L2, Hello world!" + HPAD;
    private static final String H3 = "L3, Hello {}!" + HPAD;
    private static final String H4 = "L4, Hello {}!" + HPAD;
    private static final String H5 = "L5, Hello world!" + HPAD;
    private static final String H6 = "L6, Hello world!" + HPAD;
    private static final String H7 = "L7, Hello world!" + HPAD;
    private static final String H8 = "L8, Hello {}, {}, {}, {}, {}, {}, {}, {}, {}!" + HPAD;
    private static final String H9 = "L9, Hello {}, {}, {}, {}, {}, {}, {}, {}, {}!" + HPAD;
    private static final String H10 = "L10, Hello world!" + HPAD;
    private static final String H11 = "L11, Hello world!" + HPAD;
    private static final String H12 = "L12, Hello world!" + HPAD;
    private static final String H13 = "L13, Hello {}, {}, {}, {}, {}, {}, {}, {}, {}!" + HPAD;
    private static final String COMPLEX_PATTERN = "Hello {} " + CPAD;
    private static final Marker MARKER = MarkerManager.getMarker("marker");
    private static final Marker MK1;
    static {
        MK1 = MarkerManager.getMarker("MARKER1");
        MK1.addParents(MarkerManager.getMarker("MARKER2"),
                       MarkerManager.getMarker("MARKER3"));
    }
    private static final RuntimeException THROWABLE = new RuntimeException("Oh no!");

    // heavy: mirrors Log4JLoggerBenchmark.runLogLikeHell (14 messages/op).
    @Benchmark
    @Fork(FORK_COUNT)
    @Threads(PARALLEL_THREAD_COUNT)
    @BenchmarkMode(Mode.Throughput)
    @Warmup(iterations = WARMUP_ITERATIONS, time = WARMUP_TIME_IN_SECONDS_PER_ITERATION)
    @Measurement(iterations = MEASUREMENT_ITERATIONS, time = MEASUREMENT_TIME_IN_SECONDS_PER_ITERATION)
    public void logHeavy(PerThread t) {
        org.apache.logging.log4j.Logger l = t.logger;
        l.info(H0);
        l.info(H1);
        l.info(MARKER, H2, THROWABLE);
        l.info(H3, "placeholder");
        l.info(H4, "placeholder", THROWABLE);
        l.info(MARKER, H5);
        l.info(MARKER, H6);
        l.info(H7);
        l.info(H8, 1, 2, 3, 4, 5, 6, 7, 8, 9);
        l.info(H9, 1, 2, 3, 4, 5, 6, 7, 8, 9);
        l.info(H10);
        l.info(MARKER, H11);
        l.info(MARKER, H12);
        l.info(H13, 1, 2, 3, 4, 5, 6, 7, 8, 9);
    }

    // complex: mirrors Log4JLoggerBenchmark.runSingleComplexLog (3 markers,
    // 3 MDC entries, an exception -> stack trace dominates the write).
    @Benchmark
    @Fork(FORK_COUNT)
    @Threads(PARALLEL_THREAD_COUNT)
    @BenchmarkMode(Mode.Throughput)
    @Warmup(iterations = WARMUP_ITERATIONS, time = WARMUP_TIME_IN_SECONDS_PER_ITERATION)
    @Measurement(iterations = MEASUREMENT_ITERATIONS, time = MEASUREMENT_TIME_IN_SECONDS_PER_ITERATION)
    public void logComplex(PerThread t) {
        ThreadContext.put("user", "user1");
        ThreadContext.put("transaction", "t34");
        ThreadContext.put("session", "session56");
        t.logger.info(MK1, COMPLEX_PATTERN, "World", THROWABLE);
        ThreadContext.clearMap();
    }
}
