/**
 * The shared compiler temporary probe (P8), the mechanism Adobe's fourth hotfix changes.
 * See docs/root-cause.md.
 *
 * Earlier builds of this handler also held lock stress tests P1 to P7 for Adobe's lock-based
 * hotfixes (first and third). They are kept at git tag research-notes-2026-10.
 *
 * Contract: { "ok": bool, "probe": name, "variant": ..., "elapsedMs": n, "detail": {...} },
 * HTTP 500 when ok is false.
 *
 * ACF note: cfthread bodies cannot see the enclosing function's local/arguments scopes, and
 * cfthread attributes are deep-copied, so only simple values go through attributes; the latch
 * and the result struct are shared through the request scope.
 */
component extends="coldbox.system.RestHandler" {

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

	// ------------------------------------------------------------------ private

	private numeric function clampInt( required struct rc, required string key, required numeric dflt, required numeric lo, required numeric hi ) {
		var v = arguments.rc.keyExists( arguments.key ) && isNumeric( arguments.rc[ arguments.key ] ) ? int( arguments.rc[ arguments.key ] ) : arguments.dflt;
		return max( arguments.lo, min( arguments.hi, v ) );
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
