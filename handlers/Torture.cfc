/**
 * Adversarial probes for Adobe's per-class construction-lock hotfix (v3, test server perclass-u23).
 *
 * The v3 jar wraps TemplateProxyFactory.resolveName in a ReentrantLock per CFC file path,
 * held together with every ancestor's lock until the outermost resolveName returns. That
 * body includes the pseudo-constructor but not init(). Each probe here isolates one
 * consequence of that design (see docs/adobe-hotfixes/3-third-hotfix-static-analysis.md)
 * and runs identically on every test server, so the test servers can be compared probe by probe.
 *
 * Contract for every action:
 *   { "ok": bool, "probe": name, "variant": ..., "elapsedMs": n, "detail": {...} }
 *   HTTP 500 when ok is false. Every wait is bounded, except that P2's parked threads
 *   are left parked on purpose (they cannot be interrupted; the test server must be restarted).
 *
 * Constructions use createObject( "component", path ) without init(), so the thing timed is
 * resolveName (metadata, extends chain, pseudo-constructor), not init().
 *
 * ACF notes that shaped this file:
 *   - cfthread bodies cannot see the enclosing function's local/arguments scopes, and
 *     cfthread attributes are deep-copied. So only simple values go through attributes;
 *     latches and result structs are shared through the request scope, which the request
 *     and all of its cfthreads share by reference.
 *   - CFThread has a bounded pool (Administrator setting). Threads beyond it queue rather
 *     than start, so the start barrier's own wait is bounded and reported (barrierOk), and
 *     P4 deliberately runs without a barrier.
 */
component extends="coldbox.system.RestHandler" {

	// P1 pairs: two construction specs each. mode create = createObject without init,
	// mode new = `new models.torture.SlowInit()` (the only class that needs init to run).
	variables.P1_PAIRS = [
		"same",
		"unrelated",
		"siblings",
		"slowinit",
		"alias",
		"mapping",
		"outer"
	];

	// What the plan predicts for each P1 pair on each test server design. Reported, never judged here.
	variables.P1_EXPECTED = {
		"same"      : { "none" : "parallel", "global" : "serial", "perclass" : "serial" },
		"unrelated" : { "none" : "parallel", "global" : "serial", "perclass" : "parallel" },
		"siblings"  : { "none" : "parallel", "global" : "serial", "perclass" : "serial" },
		"slowinit"  : { "none" : "parallel", "global" : "parallel", "perclass" : "parallel" },
		"alias"     : { "none" : "parallel", "global" : "serial", "perclass" : "serial" },
		"mapping"   : { "none" : "parallel", "global" : "serial", "perclass" : "serial" },
		"outer"     : { "none" : "parallel", "global" : "serial", "perclass" : "serial" }
	};

	/**
	 * GET /torture/p1?pair=<name>|all&ms=200&reps=5
	 *
	 * Lock-identity timing matrix. Two cfthreads released together by a latch each construct
	 * one class whose pseudo-constructor sleeps ms. Median wall time over reps:
	 * serial if >= 1.8 x ms, parallel if <= 1.4 x ms, otherwise unclear.
	 *
	 * Expected (stock / v1 global / v3 per-class):
	 *   same      P / S / S
	 *   unrelated P / S / P   (the one pair where v3 should beat v1)
	 *   siblings  P / S / S   (shared ancestor lock held across the leaf pseudo-constructor)
	 *   slowinit  P / P / P   (sleep is in init(), which runs after resolveName: unprotected)
	 *   alias     P / S / S   (same file, different case; P on v3 means the lock key splits,
	 *                          a correctness hole)
	 *   mapping   P / S / S   (same file via the /app mapping; same reasoning as alias)
	 *   outer     P / S / S   (Outer's pseudo-constructor builds SlowLeafA, taking its lock)
	 *
	 * ok is false only if a construction errored or timed out; the verdict is the result.
	 */
	function p1( event, rc, prc ) {
		var t0   = getTickCount();
		var pair = rc.keyExists( "pair" ) ? lCase( trim( rc.pair ) ) : "same";
		var ms   = clampInt( rc, "ms", 200, 20, 2000 );
		var reps = clampInt( rc, "reps", 5, 1, 20 );

		if ( pair == "all" ) {
			var matrix = {};
			var allOk  = true;
			for ( var name in variables.P1_PAIRS ) {
				matrix[ name ] = runP1Pair( name, ms, reps );
				allOk = allOk && matrix[ name ].ok;
			}
			return finish( event, "p1", "all", t0, allOk, { "ms" : ms, "reps" : reps, "matrix" : matrix } );
		}

		if ( !arrayFindNoCase( variables.P1_PAIRS, pair ) ) {
			return finish( event, "p1", pair, t0, false, { "error" : "unknown pair; use one of #arrayToList( variables.P1_PAIRS )# or all" } );
		}
		var result = runP1Pair( pair, ms, reps );
		result[ "ms" ]   = ms;
		result[ "reps" ] = reps;
		return finish( event, "p1", pair, t0, result.ok, result );
	}

	/**
	 * GET /torture/p2?side=a|b&runId=...&joinMs=10000
	 *
	 * Mutual lazy init, one side per HTTP request. The driver fires side=a and side=b
	 * concurrently with the same runId so both requests share the application keys.
	 * This action deliberately does NOT clear those keys (that would sabotage the other
	 * side); call /torture/reset before a run.
	 *
	 * Expected: stock and v1 complete; v3 deadlocks (MutualA's lock held while waiting for
	 * MutualB's and vice versa). The join times out, ok=false, detail.timedOut=true, and the
	 * cfthread stays parked for the life of the JVM. RESTART THE ARM AFTER THIS PROBE.
	 */
	function p2( event, rc, prc ) {
		var t0     = getTickCount();
		var side   = ( rc.keyExists( "side" ) && lCase( rc.side ) == "b" ) ? "b" : "a";
		var runId  = rc.keyExists( "runId" ) && len( trim( rc.runId ) ) ? safeId( rc.runId ) : safeId( createUUID() );
		var joinMs = clampInt( rc, "joinMs", 10000, 1000, 60000 );

		request.tortureRunId = runId;
		var run = runConcurrent(
			specs  = [ { "path" : "models.torture.Mutual" & uCase( side ), "mode" : "create" } ],
			joinMs = joinMs
		);
		var detail = run;
		detail[ "runId" ]  = runId;
		detail[ "joinMs" ] = joinMs;
		detail[ "note" ]   = "If timedOut is true the thread is parked forever; restart the test server.";
		return finish( event, "p2", side, t0, !run.timedOut && run.allOk, detail );
	}

	/**
	 * GET /torture/p2both?runId=...&joinMs=10000
	 *
	 * Single-request reproduction of the mutual lazy-init deadlock: two cfthreads released by
	 * a latch, one constructing MutualA and one MutualB. Clears its own run's keys first
	 * and warms both classes under a separate run id (single-threaded, so it cannot deadlock).
	 *
	 * Expected: stock and v1 complete; v3 times out (ok=false, detail.timedOut=true) and
	 * leaves two threads parked on each other's ReentrantLock. RESTART THE ARM AFTERWARDS.
	 */
	function p2both( event, rc, prc ) {
		var t0     = getTickCount();
		var runId  = rc.keyExists( "runId" ) && len( trim( rc.runId ) ) ? safeId( rc.runId ) : safeId( createUUID() );
		var joinMs = clampInt( rc, "joinMs", 10000, 1000, 60000 );

		// Warm both classes single-threaded under a throwaway id, then drop its keys.
		var warmId = "warm" & safeId( createUUID() );
		request.tortureRunId = warmId;
		createObject( "component", "models.torture.MutualA" );
		clearRunKeys( warmId );

		clearRunKeys( runId );
		request.tortureRunId = runId;
		var run = runConcurrent(
			specs  = [
				{ "path" : "models.torture.MutualA", "mode" : "create" },
				{ "path" : "models.torture.MutualB", "mode" : "create" }
			],
			joinMs = joinMs
		);
		var detail = run;
		detail[ "runId" ]  = runId;
		detail[ "joinMs" ] = joinMs;
		detail[ "note" ]   = "If timedOut is true both threads are parked forever; restart the test server.";
		return finish( event, "p2both", "both", t0, !run.timedOut && run.allOk, detail );
	}

	/**
	 * GET /torture/p3?variant=same|unrelated&holder=cfc|thread
	 *
	 * cflock interlock. Thread 1 holds named lock "torture-L" and, while holding it,
	 * constructs LockTargetX. Thread 2 starts ~10 ms later and constructs LockTargetX
	 * (variant same) or LockTargetZ (variant unrelated); both targets take "torture-L"
	 * (timeout 3 s) in their pseudo-constructor.
	 *
	 * holder=cfc (default): thread 1 takes "torture-L" inside LockHolderY's pseudo-constructor.
	 *   stock OK both; v1 OK both (thread 2 cannot even start constructing until LockHolderY,
	 *   which owns the global monitor, is done); v3 lock timeout in same, OK in unrelated.
	 * holder=thread: thread 1 takes "torture-L" in plain request code, outside any
	 *   construction. This is the plan-table shape:
	 *   stock OK both; v1 lock timeout both; v3 lock timeout in same only.
	 *
	 * ok = no thread reported an error.
	 */
	function p3( event, rc, prc ) {
		var t0      = getTickCount();
		var variant = ( rc.keyExists( "variant" ) && lCase( rc.variant ) == "unrelated" ) ? "unrelated" : "same";
		var holder  = ( rc.keyExists( "holder" ) && lCase( rc.holder ) == "thread" ) ? "thread" : "cfc";
		var target  = variant == "same" ? "models.torture.LockTargetX" : "models.torture.LockTargetZ";

		// Warm serially (this also compiles LockTargetX through LockHolderY).
		createObject( "component", "models.torture.LockTargetX" );
		createObject( "component", "models.torture.LockTargetZ" );
		createObject( "component", "models.torture.LockHolderY" );

		var first = holder == "cfc"
			? { "path" : "models.torture.LockHolderY", "mode" : "create" }
			: { "path" : "models.torture.LockTargetX", "mode" : "lockThenCreate" };

		var run = runConcurrent(
			specs     = [ first, { "path" : target, "mode" : "create" } ],
			joinMs    = 15000,
			staggerMs = 10
		);

		var lockTimeout = false;
		for ( var key in run.threads ) {
			var t = run.threads[ key ];
			if ( t.keyExists( "error" ) && findNoCase( "timeout", t.error ) ) {
				lockTimeout = true;
			}
		}
		var detail = run;
		detail[ "holder" ]      = holder;
		detail[ "lockTimeout" ] = lockTimeout;
		return finish( event, "p3", variant & "/" & holder, t0, run.allOk && !run.timedOut, detail );
	}

	/**
	 * GET /torture/p4?n=200&c=16
	 *
	 * Lock leak. n constructions spread over c cfthreads, cycling through Thrower (throws
	 * from its pseudo-constructor every 3rd construction), ThrowerChild (its base's
	 * pseudo-constructor throws during extends resolution) and Catcher (catches a nested
	 * Thrower failure). Then 4 single-construction threads hit Aborter with `abort` enabled.
	 * Every error is caught and counted, never judged.
	 *
	 * The verdict is the final check: with every failure switch turned off, construct
	 * Thrower, ThrowerChild, Catcher and Aborter once each in their own thread, 10 s deadline.
	 * A lock left held by any exceptional path would hang that construction.
	 *
	 * Expected on every test server: ok (a hang on the v3 jar is a FAIL: leaked lock).
	 * Not covered: a request timeout interrupting a construction (plan item; needs a request
	 * killed mid-pseudo-constructor, which cfthread cannot reproduce faithfully).
	 */
	function p4( event, rc, prc ) {
		var t0 = getTickCount();
		var n  = clampInt( rc, "n", 200, 1, 5000 );
		var c  = clampInt( rc, "c", 16, 1, 64 );

		var path = "";
		var i    = 0;

		// Warm with every failure switch off.
		setP4Switches( throwEvery = 0, baseThrows = false, abortOn = false );
		for ( path in p4Classes() ) {
			createObject( "component", path );
		}
		createObject( "component", "models.torture.Aborter" );

		// Storm phase.
		setP4Switches( throwEvery = 3, baseThrows = true, abortOn = false );
		var perThread = ceiling( n / c );
		var specs = [];
		for ( i = 1; i <= c; i++ ) {
			specs.append( { "path" : "", "mode" : "p4mix", "reps" : perThread } );
		}
		var storm = runConcurrent( specs = specs, joinMs = 60000, useBarrier = false );

		// Abort phase: each abort ends its own thread, so one construction per thread.
		setP4Switches( throwEvery = 0, baseThrows = false, abortOn = true );
		var aborts = runConcurrent(
			specs      = [
				{ "path" : "models.torture.Aborter", "mode" : "create" },
				{ "path" : "models.torture.Aborter", "mode" : "create" },
				{ "path" : "models.torture.Aborter", "mode" : "create" },
				{ "path" : "models.torture.Aborter", "mode" : "create" }
			],
			joinMs     = 10000,
			useBarrier = false
		);

		// Final check: everything clean, one construction of each class, 10 s deadline.
		setP4Switches( throwEvery = 0, baseThrows = false, abortOn = false );
		var finalSpecs = [];
		for ( path in p4Classes() ) {
			finalSpecs.append( { "path" : path, "mode" : "create" } );
		}
		finalSpecs.append( { "path" : "models.torture.Aborter", "mode" : "create" } );
		// ("final" is a reserved word in ACF, hence finalRun.)
		var finalRun = runConcurrent( specs = finalSpecs, joinMs = 10000, useBarrier = false );

		var stormOk = 0;
		var stormErr = 0;
		for ( var key in storm.threads ) {
			stormOk  += storm.threads[ key ].keyExists( "okCount" ) ? storm.threads[ key ].okCount : 0;
			stormErr += storm.threads[ key ].keyExists( "errorCount" ) ? storm.threads[ key ].errorCount : 0;
		}

		var detail = {
			"n"                    : n,
			"c"                    : c,
			"stormConstructionsOk" : stormOk,
			"stormErrorsCaught"    : stormErr,
			"stormTimedOut"        : storm.timedOut,
			"stormWallMs"          : storm.wallMs,
			"abortThreads"         : aborts,
			"final"                : finalRun
		};
		return finish( event, "p4", "n#n#-c#c#", t0, !finalRun.timedOut && finalRun.allOk, detail );
	}

	/**
	 * GET /torture/p5?target=same|sibling|unrelated&joinMs=3000
	 *
	 * cfthread inside construction. The request thread constructs ThreadSpawner, whose
	 * pseudo-constructor (via a method; see ThreadSpawner.cfc) spawns a cfthread that
	 * constructs the target and joins it with joinMs. Targets: ThreadSpawner itself (depth
	 * guarded), SpawnerSibling (shares SpawnerBase), SlowLeafB (unrelated, sleep 0).
	 * After the construction returns, waits up to 10 s for the child to finish (recovered).
	 *
	 * Expected: stock completes all; v1 join timeout for all targets, then recovers;
	 * v3 join timeout for same and sibling (shared lock), completes unrelated, recovers.
	 * ok = no join timeout, no error, and the child finished.
	 */
	function p5( event, rc, prc ) {
		var t0      = getTickCount();
		var target  = rc.keyExists( "target" ) && listFindNoCase( "same,sibling,unrelated", rc.target ) ? lCase( rc.target ) : "same";
		var joinMs  = clampInt( rc, "joinMs", 3000, 100, 30000 );
		var targets = {
			"same"      : "models.torture.ThreadSpawner",
			"sibling"   : "models.torture.SpawnerSibling",
			"unrelated" : "models.torture.SlowLeafB"
		};

		request.tortureSleepMs = 0;
		// Warm with the depth guard up, so ThreadSpawner does not spawn while warming.
		request.tortureDepth = 1;
		createObject( "component", "models.torture.ThreadSpawner" );
		createObject( "component", "models.torture.SpawnerSibling" );
		createObject( "component", "models.torture.SlowLeafB" );

		request.tortureP5    = { "target" : targets[ target ], "joinMs" : joinMs };
		request.tortureDepth = 0;
		var detail = { "targetPath" : targets[ target ], "joinMs" : joinMs };

		var c0 = getTickCount();
		try {
			createObject( "component", "models.torture.ThreadSpawner" );
		} catch ( any e ) {
			detail[ "error" ] = e.message;
		}
		detail[ "constructMs" ] = getTickCount() - c0;

		// Recovery: the child should finish once the parent's locks are released.
		var deadline = getTickCount() + 10000;
		while (
			request.tortureP5.keyExists( "spawnTick" )
			&& !request.tortureP5.keyExists( "childDoneTick" )
			&& getTickCount() < deadline
		) {
			sleep( 20 );
		}
		var p5 = request.tortureP5;
		detail[ "timedOut" ]   = p5.keyExists( "timedOut" ) ? p5.timedOut : true;
		detail[ "joinWaitMs" ] = p5.keyExists( "joinWaitMs" ) ? p5.joinWaitMs : -1;
		detail[ "recovered" ]  = p5.keyExists( "childDoneTick" );
		detail[ "childOk" ]    = p5.keyExists( "childOk" );
		if ( p5.keyExists( "childError" ) ) {
			detail[ "childError" ] = p5.childError;
		}
		if ( p5.keyExists( "childDoneTick" ) && p5.keyExists( "spawnTick" ) ) {
			detail[ "childLatencyMs" ] = p5.childDoneTick - p5.spawnTick;
		}
		if ( !p5.keyExists( "spawnTick" ) ) {
			detail[ "spawnError" ] = "ThreadSpawner never reached spawnAndJoin()";
		}

		var ok = !detail.timedOut && !detail.keyExists( "error" ) && detail.recovered && detail.childOk;
		return finish( event, "p5", target, t0, ok, detail );
	}

	/**
	 * GET /torture/p6?reps=200
	 *
	 * duplicate() of an already-built SlowSibA (sleep 0) in one thread, reps times, while a
	 * second thread constructs SlowSibA reps times. duplicate() goes through
	 * resolveNameForDuplicate, which bypasses the construction lock on v1 and v3; this checks
	 * the two paths cannot deadlock each other.
	 *
	 * Expected on every test server: ok (both finish within 10 s).
	 */
	function p6( event, rc, prc ) {
		var t0   = getTickCount();
		var reps = clampInt( rc, "reps", 200, 1, 5000 );

		request.tortureSleepMs  = 0;
		request.tortureDupSource = createObject( "component", "models.torture.SlowSibA" );

		var run = runConcurrent(
			specs  = [
				{ "path" : "", "mode" : "duplicate", "reps" : reps },
				{ "path" : "models.torture.SlowSibA", "mode" : "create", "reps" : reps }
			],
			joinMs = 10000
		);
		var detail = run;
		detail[ "reps" ] = reps;
		return finish( event, "p6", "dup-vs-construct", t0, run.allOk && !run.timedOut, detail );
	}

	/**
	 * GET /torture/p7
	 *
	 * Constructs models.torture.many.Many01..Many64 once each and reports the lock
	 * fingerprint before and after. The v3 map is never evicted, so the first call after a
	 * JVM start should grow it by >= 64 and later calls by 0; it must never shrink.
	 * Minor finding (unbounded growth with distinct CFC files), documented not failed.
	 *
	 * ok = all 64 constructions succeeded.
	 */
	function p7( event, rc, prc ) {
		var t0     = getTickCount();
		var before = lockFingerprint();
		var built  = 0;
		var errors = [];

		for ( var i = 1; i <= 64; i++ ) {
			try {
				createObject( "component", "models.torture.many.Many" & numberFormat( i, "00" ) );
				built++;
			} catch ( any e ) {
				errors.append( "Many#numberFormat( i, '00' )#: #e.message#" );
			}
		}

		var after  = lockFingerprint();
		var detail = { "constructed" : built, "errors" : errors, "before" : before, "after" : after };
		if ( isNumeric( before.mapSize ) && isNumeric( after.mapSize ) ) {
			detail[ "mapGrowth" ]    = after.mapSize - before.mapSize;
			detail[ "grewBy64" ]     = after.mapSize - before.mapSize >= 64;
			detail[ "neverShrinks" ] = after.mapSize >= before.mapSize;
		}
		return finish( event, "p7", "many64", t0, built == 64, detail );
	}

	/**
	 * GET /torture/p8?threads=32&reps=50&ms=2
	 *
	 * Shared compiler temporary (the mechanism Adobe's fourth hotfix changes). `threads`
	 * cfthreads, released together, each call the TempVarProbe SINGLETON `reps` times to build
	 * an inline struct, an inline array and an invoke() argument struct around the thread's own
	 * token, each literal inside a conditional expression (the shape whose compiler temporary is
	 * not declared as a local; WireBox's Builder.buildCFC uses it), with `ms` of sleep inside
	 * each literal. Before v4 that temporary (`___IMPLICITARRYSTRUCTVAR<n>`) is written to the
	 * singleton's variables scope, which every request shares, so threads get back each other's
	 * half-built values. v4 keeps it in the function's local scope.
	 *
	 * Reported: crossings per form, the first few samples, and the leaked temporaries in the
	 * singleton's variables scope before and after (a single-threaded build is enough to show
	 * them on an unfixed engine). ok = 0 crossings, 0 leaked keys, 0 errors, every thread done.
	 *
	 * Expected: stock, v1 and v3 FAIL (the locks are around construction, not around this);
	 * v4 PASS.
	 */
	function p8( event, rc, prc ) {
		var t0      = getTickCount();
		var threads = clampInt( rc, "threads", 32, 1, 64 );
		var reps    = clampInt( rc, "reps", 50, 1, 5000 );
		var ms      = clampInt( rc, "ms", 2, 0, 50 );
		var probe   = getInstance( "models.torture.TempVarProbe" );

		// Single-threaded first: one build, then look at the singleton's variables scope.
		probe.build( "warm", 0 );
		var leakedBefore = probe.leakedKeys();

		var runKey = "tortureP8_" & replace( createUUID(), "-", "", "all" );
		var ctx    = {
			"go"      : createObject( "java", "java.util.concurrent.CountDownLatch" ).init( javaCast( "int", 1 ) ),
			"probe"   : probe,
			"results" : {}
		};
		request[ runKey ] = ctx;

		var names = [];
		var i     = 0;
		var tName = "";
		for ( i = 1; i <= threads; i++ ) {
			tName = runKey & "_" & i;
			names.append( tName );
			thread name="#tName#" action="run" runKey="#runKey#" idx="#i#" reps="#reps#" ms="#ms#" {
				var tCtx   = request[ attributes.runKey ];
				var tToken = "t" & attributes.idx & "-" & replace( createUUID(), "-", "", "all" );
				var tRes   = { "structCrossings" : 0, "arrayCrossings" : 0, "invokeCrossings" : 0, "errors" : 0, "samples" : [] };
				var tRep   = 0;
				var tS     = {};
				var tA     = [];
				var tV     = "";
				try {
					tCtx.go.await( javaCast( "long", 30000 ), createObject( "java", "java.util.concurrent.TimeUnit" ).MILLISECONDS );
					for ( tRep = 1; tRep <= attributes.reps; tRep++ ) {
						tS = tCtx.probe.build( tToken, attributes.ms );
						if ( tS.token != tToken || tS.again != tToken ) {
							tRes.structCrossings++;
							if ( tRes.samples.len() < 3 ) tRes.samples.append( "struct: expected #tToken#, got #tS.token# / #tS.again#" );
						}
						tA = tCtx.probe.buildArray( tToken, attributes.ms );
						if ( tA[ 1 ] != tToken || tA[ 2 ] != tToken ) {
							tRes.arrayCrossings++;
							if ( tRes.samples.len() < 3 ) tRes.samples.append( "array: expected #tToken#, got #tA[ 1 ]# / #tA[ 2 ]#" );
						}
						tV = tCtx.probe.buildViaInvoke( tToken, attributes.ms );
						if ( tV != tToken ) {
							tRes.invokeCrossings++;
							if ( tRes.samples.len() < 3 ) tRes.samples.append( "invoke: expected #tToken#, got #tV#" );
						}
					}
				} catch ( any tErr ) {
					tRes.errors++;
					tRes.samples.append( "error: " & tErr.message );
				}
				tCtx.results[ "t" & attributes.idx ] = tRes;
			}
		}

		sleep( 100 );
		var goTick = getTickCount();
		ctx.go.countDown();
		var deadline = goTick + 120000;
		for ( tName in names ) {
			thread action="join" name="#tName#" timeout="#max( 1, deadline - getTickCount() )#";
		}
		var wallMs = getTickCount() - goTick;

		var totals  = { "structCrossings" : 0, "arrayCrossings" : 0, "invokeCrossings" : 0, "errors" : 0, "finished" : 0 };
		var samples = [];
		for ( var key in ctx.results ) {
			var r = ctx.results[ key ];
			totals.structCrossings += r.structCrossings;
			totals.arrayCrossings  += r.arrayCrossings;
			totals.invokeCrossings += r.invokeCrossings;
			totals.errors          += r.errors;
			totals.finished++;
			for ( var s in r.samples ) {
				if ( samples.len() < 8 ) samples.append( s );
			}
		}
		structDelete( request, runKey );
		var leakedAfter = probe.leakedKeys();
		var crossings   = totals.structCrossings + totals.arrayCrossings + totals.invokeCrossings;
		var ok          = crossings == 0 && leakedBefore.len() == 0 && leakedAfter.len() == 0 && totals.errors == 0 && totals.finished == threads;

		var detail = {
			"threads"            : threads,
			"reps"               : reps,
			"ms"                 : ms,
			"builds"             : threads * reps * 3,
			"wallMs"             : wallMs,
			"finishedThreads"    : totals.finished,
			"structCrossings"    : totals.structCrossings,
			"arrayCrossings"     : totals.arrayCrossings,
			"invokeCrossings"    : totals.invokeCrossings,
			"crossings"          : crossings,
			"errors"             : totals.errors,
			"leakedKeysBefore"   : leakedBefore,
			"leakedKeysAfter"    : leakedAfter,
			"variablesKeyCount"  : probe.variablesKeyCount(),
			"samples"            : samples,
			"verdict"            : "crossings=#crossings# leakedKeys=#leakedAfter.len()#"
		};
		return finish( event, "p8", "tempvar", t0, ok, detail );
	}

	/**
	 * GET /torture/locks
	 *
	 * The construction-lock fingerprint alone, for scripts to poll (e.g. map size during a
	 * endurance test). Always ok; fields that cannot be reflected read "unavailable".
	 */
	function locks( event, rc, prc ) {
		var t0 = getTickCount();
		return finish( event, "locks", "fingerprint", t0, true, lockFingerprint() );
	}

	/**
	 * GET /torture/reset
	 *
	 * Clears every application key starting with torture_ (P2's lazy-init slots). Parked P2
	 * threads are not affected; only a JVM restart clears those.
	 */
	function reset( event, rc, prc ) {
		var t0      = getTickCount();
		var removed = 0;
		for ( var key in structKeyArray( application ) ) {
			if ( left( key, 8 ) == "torture_" ) {
				structDelete( application, key );
				removed++;
			}
		}
		return finish( event, "reset", "application", t0, true, { "removed" : removed } );
	}

	// ------------------------------------------------------------------ private

	/**
	 * Reflects on TemplateProxyFactory's static fields to identify the lock design:
	 * v1 has CONSTRUCTION_LOCK (global monitor), v3 has CLASS_CONSTRUCTION_LOCKS (map).
	 * Each step is independent so one failure cannot hide the others.
	 */
	private struct function lockFingerprint() {
		var result = {
			"hasGlobalLock"  : "unavailable",
			"hasPerClassMap" : "unavailable",
			"mapSize"        : "unavailable",
			"design"         : "unavailable"
		};
		var tpfClass = "";
		try {
			// Same idiom Benchmark.classSources() uses; proven on every test server.
			tpfClass = createObject( "java", "coldfusion.runtime.TemplateProxyFactory" ).getClass();
		} catch ( any e ) {
			try {
				// Fallback through the context classloader, which is the one ACF loads
				// lib/updates overlays into.
				var loader = createObject( "java", "java.lang.Thread" ).currentThread().getContextClassLoader();
				tpfClass = loader.loadClass( "coldfusion.runtime.TemplateProxyFactory" );
			} catch ( any e2 ) {
				result[ "error" ] = e.message & " / " & e2.message;
				return result;
			}
		}

		try {
			tpfClass.getDeclaredField( "CONSTRUCTION_LOCK" );
			result[ "hasGlobalLock" ] = true;
		} catch ( any e ) {
			result[ "hasGlobalLock" ] = findNoCase( "NoSuchField", e.message & " " & ( e.type ?: "" ) & " " & ( e.detail ?: "" ) ) ? false : "unavailable";
		}

		var mapField = "";
		try {
			mapField = tpfClass.getDeclaredField( "CLASS_CONSTRUCTION_LOCKS" );
			result[ "hasPerClassMap" ] = true;
		} catch ( any e ) {
			result[ "hasPerClassMap" ] = findNoCase( "NoSuchField", e.message & " " & ( e.type ?: "" ) & " " & ( e.detail ?: "" ) ) ? false : "unavailable";
		}

		// "unavailable" is not boolean, so isBoolean() separates known answers from unknowns.
		var perClass   = isBoolean( result.hasPerClassMap ) && result.hasPerClassMap;
		var noPerClass = isBoolean( result.hasPerClassMap ) && !result.hasPerClassMap;
		var globalLock = isBoolean( result.hasGlobalLock ) && result.hasGlobalLock;
		var noGlobal   = isBoolean( result.hasGlobalLock ) && !result.hasGlobalLock;

		if ( perClass ) {
			try {
				mapField.setAccessible( true );
				result[ "mapSize" ] = mapField.get( javaCast( "null", "" ) ).size();
			} catch ( any e ) {
				result[ "mapSize" ] = "unavailable";
			}
		} else if ( noPerClass ) {
			result[ "mapSize" ] = 0;
		}

		if ( perClass ) {
			result[ "design" ] = "perclass";
		} else if ( globalLock ) {
			result[ "design" ] = "global";
		} else if ( noPerClass && noGlobal ) {
			result[ "design" ] = "none";
		}
		return result;
	}

	/** One P1 pair: warm both classes, then reps timed concurrent constructions. */
	private struct function runP1Pair( required string pair, required numeric ms, required numeric reps ) {
		var specs = p1Specs( arguments.pair );

		// Warm each class once, serially, with no sleep, so compilation is not timed.
		request.tortureSleepMs = 0;
		for ( var spec in specs ) {
			constructSpec( spec.path, spec.mode, 1 );
		}
		request.tortureSleepMs = arguments.ms;

		var walls  = [];
		var runs   = [];
		var ok     = true;
		for ( var r = 1; r <= arguments.reps; r++ ) {
			var run = runConcurrent( specs = specs, joinMs = max( 10000, arguments.ms * 8 ) );
			runs.append( run );
			if ( run.timedOut || !run.allOk ) {
				ok = false;
			} else {
				walls.append( run.wallMs );
			}
		}

		var med     = walls.len() ? median( walls ) : -1;
		var verdict = "unclear";
		if ( med < 0 ) {
			verdict = "error";
		} else if ( med >= 1.8 * arguments.ms ) {
			verdict = "serial";
		} else if ( med <= 1.4 * arguments.ms ) {
			verdict = "parallel";
		}
		return {
			"ok"       : ok,
			"pair"     : arguments.pair,
			"a"        : specs[ 1 ].path,
			"b"        : specs[ 2 ].path,
			"medianMs" : med,
			"ratio"    : med > 0 ? round( med / arguments.ms * 100 ) / 100 : -1,
			"verdict"  : verdict,
			"expected" : variables.P1_EXPECTED[ arguments.pair ],
			"wallsMs"  : walls,
			"runs"     : runs
		};
	}

	private array function p1Specs( required string pair ) {
		switch ( arguments.pair ) {
			case "unrelated":
				return [ createSpec( "models.torture.SlowLeafA" ), createSpec( "models.torture.SlowLeafB" ) ];
			case "siblings":
				return [ createSpec( "models.torture.SlowSibA" ), createSpec( "models.torture.SlowSibB" ) ];
			case "slowinit":
				return [ { "path" : "models.torture.SlowInit", "mode" : "new" }, { "path" : "models.torture.SlowInit", "mode" : "new" } ];
			case "alias":
				// Same file, different spelling: the v3 key is the resolved file path.
				return [ createSpec( "models.torture.SlowLeafA" ), createSpec( "MODELS.TORTURE.slowleafa" ) ];
			case "mapping":
				// Same file reached through the /app mapping declared in Application.cfc.
				return [ createSpec( "models.torture.SlowLeafA" ), createSpec( "app.models.torture.SlowLeafA" ) ];
			case "outer":
				return [ createSpec( "models.torture.Outer" ), createSpec( "models.torture.SlowLeafA" ) ];
			default:
				return [ createSpec( "models.torture.SlowLeafA" ), createSpec( "models.torture.SlowLeafA" ) ];
		}
	}

	private struct function createSpec( required string path ) {
		return { "path" : arguments.path, "mode" : "create" };
	}

	/**
	 * Runs one cfthread per spec and joins them all against one shared deadline.
	 *
	 * With useBarrier, every thread counts down `ready` and then waits on `go`, so the
	 * constructions start together; wallMs is measured from `go` to the last thread's own
	 * finish tick (join bookkeeping excluded). The barrier waits are bounded so a saturated
	 * cfthread pool degrades into barrierOk=false instead of a hang.
	 *
	 * Spec keys: path, mode (create|new|duplicate|lockThenCreate|p4mix), reps (default 1).
	 * staggerMs delays every thread after the first by that much after `go`.
	 */
	private struct function runConcurrent(
		required array specs,
		numeric joinMs = 10000,
		numeric staggerMs = 0,
		boolean useBarrier = true
	) {
		var runKey = "tortureRun_" & replace( createUUID(), "-", "", "all" );
		var count  = arguments.specs.len();
		var ctx    = {
			"ready"      : createObject( "java", "java.util.concurrent.CountDownLatch" ).init( javaCast( "int", count ) ),
			"go"         : createObject( "java", "java.util.concurrent.CountDownLatch" ).init( javaCast( "int", 1 ) ),
			"useBarrier" : arguments.useBarrier,
			"results"    : {}
		};
		request[ runKey ] = ctx;

		// Locals are declared once up front: the thread bodies below are compiled into this
		// function, and repeating a `var` name across loops is an ACF compile risk.
		var names     = [];
		var i         = 0;
		var tName     = "";
		var spec      = {};
		var specReps  = 1;
		var specDelay = 0;
		for ( i = 1; i <= count; i++ ) {
			tName     = runKey & "_" & i;
			spec      = arguments.specs[ i ];
			specReps  = spec.keyExists( "reps" ) ? spec.reps : 1;
			specDelay = i > 1 ? arguments.staggerMs : 0;
			names.append( tName );
			// Attributes are deep-copied into the thread, so only simple values go here.
			thread
				name="#tName#"
				action="run"
				runKey="#runKey#"
				idx="#i#"
				path="#spec.path#"
				mode="#spec.mode#"
				reps="#specReps#"
				delayMs="#specDelay#"
			{
				// Thread-body locals use a t prefix so they cannot collide with the
				// enclosing function's locals.
				var tCtx = request[ attributes.runKey ];
				var tRes = { "okCount" : 0, "errorCount" : 0, "elapsedMs" : -1 };
				var tStart = 0;
				var tRep = 0;
				try {
					if ( tCtx.useBarrier ) {
						tCtx.ready.countDown();
						tRes[ "barrierOk" ] = tCtx.go.await(
							javaCast( "long", 30000 ),
							createObject( "java", "java.util.concurrent.TimeUnit" ).MILLISECONDS
						);
					}
					if ( attributes.delayMs > 0 ) {
						sleep( attributes.delayMs );
					}
					tStart = getTickCount();
					tRes[ "startTick" ] = tStart;
					for ( tRep = 1; tRep <= attributes.reps; tRep++ ) {
						try {
							constructSpec( attributes.path, attributes.mode, tRep + attributes.idx );
							tRes.okCount++;
						} catch ( any tErr ) {
							tRes.errorCount++;
							if ( !tRes.keyExists( "error" ) ) {
								tRes[ "error" ] = tErr.message;
							}
							tRes[ "lastError" ] = tErr.message;
						}
					}
					tRes[ "elapsedMs" ] = getTickCount() - tStart;
				} catch ( any tOuter ) {
					tRes.errorCount++;
					tRes[ "error" ] = tOuter.message;
				}
				tRes[ "doneTick" ] = getTickCount();
				tCtx.results[ "t" & attributes.idx ] = tRes;
			}
		}

		var barrierOk = true;
		if ( arguments.useBarrier ) {
			barrierOk = ctx.ready.await(
				javaCast( "long", 5000 ),
				createObject( "java", "java.util.concurrent.TimeUnit" ).MILLISECONDS
			);
		}
		var goTick = getTickCount();
		ctx.go.countDown();

		var deadline = goTick + arguments.joinMs;
		var remaining = 0;
		for ( tName in names ) {
			remaining = max( 1, deadline - getTickCount() );
			thread action="join" name="#tName#" timeout="#remaining#";
		}

		var threads  = {};
		var timedOut = false;
		var allOk    = true;
		var lastDone = goTick;
		var key      = "";
		var st       = "";
		var one      = {};
		var ended    = false;
		for ( i = 1; i <= count; i++ ) {
			key = "t" & i;
			st  = "unknown";
			try {
				st = cfthread[ names[ i ] ].status;
			} catch ( any e ) {
				st = "unknown";
			}
			if ( ctx.results.keyExists( key ) ) {
				one = ctx.results[ key ];
				one[ "path" ]   = arguments.specs[ i ].path;
				one[ "mode" ]   = arguments.specs[ i ].mode;
				one[ "status" ] = st;
				one[ "ok" ]     = one.errorCount == 0;
				if ( one.keyExists( "startTick" ) ) {
					one[ "startOffsetMs" ] = one.startTick - goTick;
					structDelete( one, "startTick" );
				}
				lastDone = max( lastDone, one.doneTick );
				structDelete( one, "doneTick" );
				allOk = allOk && one.ok;
				threads[ key ] = one;
			} else {
				// No result: still running (timed out), or ended without reaching the end of
				// its body (abort ends a thread silently). cfthread status tells them apart.
				ended = listFindNoCase( "COMPLETED,TERMINATED", st ) > 0;
				threads[ key ] = {
					"path"   : arguments.specs[ i ].path,
					"mode"   : arguments.specs[ i ].mode,
					"status" : st,
					"ok"     : false,
					"ended"  : ended,
					"error"  : ended ? "thread ended without a result (abort?)" : "still running at join deadline"
				};
				if ( !ended ) {
					timedOut = true;
				}
				allOk = false;
			}
		}

		structDelete( request, runKey );
		return {
			"allOk"     : allOk,
			"timedOut"  : timedOut,
			"barrierOk" : barrierOk,
			"wallMs"    : timedOut ? -1 : lastDone - goTick,
			"threads"   : threads
		};
	}

	/** The one place a probe thread actually constructs something. */
	private void function constructSpec( required string path, required string mode, numeric iteration = 1 ) {
		switch ( arguments.mode ) {
			case "new":
				// `new` runs resolveName and then init(); only SlowInit needs this.
				new models.torture.SlowInit();
				break;
			case "duplicate":
				duplicate( request.tortureDupSource );
				break;
			case "lockThenCreate":
				// P3 holder=thread: take the named lock outside any construction.
				lock name="torture-L" type="exclusive" timeout=3 {
					sleep( 50 );
					createObject( "component", arguments.path );
				}
				break;
			case "p4mix":
				var classes = p4Classes();
				createObject( "component", classes[ ( arguments.iteration mod classes.len() ) + 1 ] );
				break;
			default:
				createObject( "component", arguments.path );
		}
	}

	private array function p4Classes() {
		return [ "models.torture.Thrower", "models.torture.ThrowerChild", "models.torture.Catcher" ];
	}

	private void function setP4Switches( required numeric throwEvery, required boolean baseThrows, required boolean abortOn ) {
		request.tortureThrowEvery = arguments.throwEvery;
		request.tortureBaseThrows = arguments.baseThrows;
		request.tortureAbort      = arguments.abortOn;
		if ( !structKeyExists( request, "tortureThrowCounter" ) ) {
			request.tortureThrowCounter = createObject( "java", "java.util.concurrent.atomic.AtomicInteger" ).init( javaCast( "int", 0 ) );
		}
	}

	private void function clearRunKeys( required string runId ) {
		structDelete( application, "torture_" & arguments.runId & "_a" );
		structDelete( application, "torture_" & arguments.runId & "_b" );
	}

	/** Run ids become application key fragments; keep them to [A-Za-z0-9]. */
	private string function safeId( required string raw ) {
		return left( reReplace( arguments.raw, "[^A-Za-z0-9]", "", "all" ), 40 );
	}

	private numeric function clampInt( required struct rc, required string key, required numeric dflt, required numeric lo, required numeric hi ) {
		var v = arguments.rc.keyExists( arguments.key ) && isNumeric( arguments.rc[ arguments.key ] ) ? int( arguments.rc[ arguments.key ] ) : arguments.dflt;
		return max( arguments.lo, min( arguments.hi, v ) );
	}

	private numeric function median( required array values ) {
		var s = duplicate( arguments.values );
		arraySort( s, "numeric" );
		var n = s.len();
		if ( n mod 2 ) {
			return s[ ( n + 1 ) / 2 ];
		}
		return ( s[ n / 2 ] + s[ n / 2 + 1 ] ) / 2;
	}

	private struct function finish(
		required any event,
		required string probe,
		required string variant,
		required numeric t0,
		required boolean ok,
		required struct detail
	) {
		if ( !arguments.ok ) {
			arguments.event.setHTTPHeader( statusCode = 500, statusText = "Torture Probe Failed" );
		}
		return {
			"ok"        : arguments.ok,
			"probe"     : arguments.probe,
			"variant"   : arguments.variant,
			"elapsedMs" : getTickCount() - arguments.t0,
			"detail"    : arguments.detail
		};
	}

}
