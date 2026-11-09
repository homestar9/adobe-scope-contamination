/**
 * Application routes. https://coldbox.ortusbooks.com/the-basics/routing
 */
component {

	function configure(){
		// Scope-contamination reproduction endpoints (handlers/Repro.cfc)
		route( "/repro/alpha" ).to( "Repro.alpha" );
		route( "/repro/bravo" ).to( "Repro.bravo" );
		route( "/repro/wire" ).to( "Repro.wire" );
		route( "/repro/tempvar" ).to( "Repro.tempvar" );
		route( "/repro/status" ).to( "Repro.status" );
		route( "/repro/stress" ).to( "Repro.stress" );

		// Database-free endpoints: server identity and ORM construction speed (handlers/Benchmark.cfc)
		route( "/benchmark/engine" ).to( "Benchmark.engine" );
		route( "/benchmark/quickconstruct" ).to( "Benchmark.quickConstruct" );

		// The shared compiler temporary probe (handlers/Torture.cfc)
		route( "/torture/p8" ).to( "Torture.p8" );

		// Conventions-Based Routing
		route( ":handler/:action?" ).end();
	}

}
