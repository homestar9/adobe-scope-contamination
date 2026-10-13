<cfscript>
/*
 * Shared-temporary reproduction for hotfix hf202300-4232227 (the fourth build, "no locks").
 *
 * One Probe instance is shared by every thread, the way a framework singleton is shared by every
 * request. Each thread asks it, many times, to build an inline struct literal around the
 * thread's own token. The compiler stores the literal in a temporary variable named
 * ___IMPLICITARRYSTRUCTVAR<n>. For a literal inside a conditional expression
 * (`cond ? {} : { ... }`) that temporary is not declared as a local, so before the fourth build
 * it is written to the shared instance's VARIABLES scope; concurrent threads overwrite each
 * other's half-built struct and a thread gets back a struct carrying another thread's token.
 * The fourth build keeps the temporary in the function's local scope. shapes.cfm lists which
 * code shapes leak and which do not.
 *
 * Expected:
 *   ColdFusion 2023 Update 23, no hotfix ................ FAIL (crossings, and ___IMPLICIT keys in variables)
 *   Update 23 + the first or third hotfix (locks) ....... FAIL (the locks are around construction, not this)
 *   Update 23 + the fourth hotfix ....................... PASS (0 crossings, no leaked keys)
 */
param name="url.threads" default="32";
param name="url.reps"    default="100";
param name="url.ms"      default="2";
threads = max( 1, min( 64, int( val( url.threads ) ) ) );
reps    = max( 1, min( 5000, int( val( url.reps ) ) ) );
ms      = max( 0, min( 50, int( val( url.ms ) ) ) );

runId = "run" & replace( createUUID(), "-", "", "all" );
application[ runId ] = {
	"probe"   : createObject( "component", "Probe" ),
	"latch"   : createObject( "java", "java.util.concurrent.CountDownLatch" ).init( 1 ),
	"results" : {}
};

// 1. Single-threaded: build once and look at the shared instance's variables scope.
application[ runId ].probe.build( "warm", 0 );
leakedSingle = application[ runId ].probe.leakedKeys();

// 2. Concurrent: every thread waits on one latch, then builds reps times with its own token.
names = [];
for ( i = 1; i <= threads; i++ ) {
	tName = "p" & i;
	names.append( tName );
	thread name="#tName#" runId=runId idx=i reps=reps ms=ms {
		var ctx   = application[ attributes.runId ];
		var token = "t" & attributes.idx & "-" & replace( createUUID(), "-", "", "all" );
		var res   = { "structCrossings" : 0, "arrayCrossings" : 0, "invokeCrossings" : 0, "errors" : 0, "sample" : "" };
		var r     = 0;
		var s     = {};
		var a     = [];
		ctx.latch.await();
		for ( r = 1; r <= attributes.reps; r++ ) {
			try {
				s = ctx.probe.build( token, attributes.ms );
				if ( s.token != token || s.again != token ) {
					res.structCrossings++;
					if ( !len( res.sample ) ) res.sample = "expected " & token & ", got " & s.token & " / " & s.again;
				}
				a = ctx.probe.buildArray( token, attributes.ms );
				if ( a[ 1 ] != token || a[ 2 ] != token ) res.arrayCrossings++;
				if ( ctx.probe.buildViaInvoke( token, attributes.ms ) != token ) res.invokeCrossings++;
			} catch ( any e ) {
				res.errors++;
				if ( !len( res.sample ) ) res.sample = "error: " & e.message;
			}
		}
		ctx.results[ "t" & attributes.idx ] = res;
	}
}
sleep( 200 );
started = getTickCount();
application[ runId ].latch.countDown();
thread action="join" name="#arrayToList( names )#" timeout="120000";
elapsedMs = getTickCount() - started;

totals  = { "structCrossings" : 0, "arrayCrossings" : 0, "invokeCrossings" : 0, "errors" : 0, "finished" : 0 };
samples = [];
for ( key in application[ runId ].results ) {
	r = application[ runId ].results[ key ];
	totals.structCrossings += r.structCrossings;
	totals.arrayCrossings  += r.arrayCrossings;
	totals.invokeCrossings += r.invokeCrossings;
	totals.errors          += r.errors;
	totals.finished++;
	if ( len( r.sample ) && samples.len() < 5 ) samples.append( r.sample );
}
leakedAfter = application[ runId ].probe.leakedKeys();
structDelete( application, runId );

crossings = totals.structCrossings + totals.arrayCrossings + totals.invokeCrossings;
failed    = crossings > 0 || leakedSingle.len() > 0 || leakedAfter.len() > 0 || totals.errors > 0 || totals.finished != threads;

writeOutput( "<h2>Shared compiler-temporary reproduction</h2>" );
writeOutput( "<p>Server: #encodeForHTML( server.coldfusion.productName )# #encodeForHTML( server.coldfusion.productVersion )#</p>" );
writeOutput( "<p>#threads# threads x #reps# builds, #ms# ms inside each literal, #elapsedMs# ms wall, #totals.finished# threads finished.</p>" );
writeOutput( "<p>Leaked temporaries in the shared instance's variables scope, single-threaded: <b>#leakedSingle.len()#</b> #encodeForHTML( arrayToList( leakedSingle ) )#<br>" );
writeOutput( "After the concurrent run: <b>#leakedAfter.len()#</b> #encodeForHTML( arrayToList( leakedAfter ) )#</p>" );
writeOutput( "<p>Structs carrying another thread's token: <b>#totals.structCrossings#</b><br>" );
writeOutput( "Arrays carrying another thread's token: <b>#totals.arrayCrossings#</b><br>" );
writeOutput( "invoke() argument structs carrying another thread's token: <b>#totals.invokeCrossings#</b><br>" );
writeOutput( "Errors: #totals.errors#</p>" );
if ( samples.len() ) {
	writeOutput( "<p>Samples:<br>" & replace( encodeForHTML( arrayToList( samples, chr( 10 ) ) ), chr( 10 ), "<br>", "all" ) & "</p>" );
}
if ( failed ) {
	writeOutput( "<p style=""color:##b00""><b>FAIL.</b> The compiler temporary for an inline literal is shared through the instance's variables scope.</p>" );
} else {
	writeOutput( "<p style=""color:##070""><b>PASS.</b> Every thread got its own value back and no temporary leaked into the shared variables scope.</p>" );
}
</cfscript>
