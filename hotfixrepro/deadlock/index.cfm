<cfscript>
/*
 * Deadlock reproduction for hotfix hf202300-4232227 (per-class construction locks).
 *
 * Two threads are released at the same instant. One constructs MutualA, the other MutualB.
 * Each pseudo-constructor constructs the other class. With a construction lock per class,
 * each thread holds its own class's lock while waiting for the other's: a permanent deadlock.
 *
 * Expected:
 *   ColdFusion 2023 Update 23, no hotfix ........ PASS (both threads finish in about 0.2 s)
 *   Update 23 + the first hotfix (global lock) .. PASS
 *   Update 23 + the per-class-lock hotfix ....... DEADLOCK (restart needed)
 *
 * To see the JVM confirm it, run  jcmd <ColdFusion pid> Thread.print -l  after a DEADLOCK result.
 * The dump ends with "Found one Java-level deadlock", naming the two cfthreads parked in
 * coldfusion.runtime.TemplateProxyFactory.resolveName on each other's ReentrantLock.
 *
 * WARNING: on the per-class-lock hotfix the two threads stay parked until ColdFusion restarts.
 */
// 1. Compile and load both classes once, single-threaded, under a throwaway run id.
request.mutualRunId = "warm" & replace( createUUID(), "-", "", "all" );
createObject( "component", "MutualA" );

// 2. The real run: both threads wait on one latch, then construct at the same moment.
runId = "run" & replace( createUUID(), "-", "", "all" );
request.mutualRunId = runId;
latch = createObject( "java", "java.util.concurrent.CountDownLatch" ).init( 1 );
application[ runId & "_latch" ] = latch;

thread name="startAtA" runId=runId {
	request.mutualRunId = attributes.runId;
	application[ attributes.runId & "_latch" ].await();
	createObject( "component", "MutualA" );
}
thread name="startAtB" runId=runId {
	request.mutualRunId = attributes.runId;
	application[ attributes.runId & "_latch" ].await();
	createObject( "component", "MutualB" );
}

sleep( 200 );              // let both threads reach the latch
started = getTickCount();
latch.countDown();         // release both at once
thread action="join" name="startAtA,startAtB" timeout="10000";
elapsedMs = getTickCount() - started;

stuck = cfthread.startAtA.status != "COMPLETED" || cfthread.startAtB.status != "COMPLETED";

server_ = server.coldfusion.productVersion;
writeOutput( "<h2>Construction-lock deadlock reproduction</h2>" );
writeOutput( "<p>Server: #encodeForHTML( server.coldfusion.productName )# #encodeForHTML( server_ )#</p>" );
writeOutput( "<p>Thread starting at MutualA: <b>#cfthread.startAtA.status#</b><br>" );
writeOutput( "Thread starting at MutualB: <b>#cfthread.startAtB.status#</b><br>" );
writeOutput( "Waited: #elapsedMs# ms</p>" );
if ( stuck ) {
	writeOutput( "<p style='color:##b00'><b>DEADLOCK.</b> Both threads are parked on each other's construction lock " );
	writeOutput( "(TemplateProxyFactory.resolveName). They will not recover. Run jcmd &lt;pid&gt; Thread.print -l to see the JVM report the deadlock, then restart ColdFusion.</p>" );
} else {
	writeOutput( "<p style='color:##070'><b>PASS.</b> Both constructions completed.</p>" );
}
</cfscript>
