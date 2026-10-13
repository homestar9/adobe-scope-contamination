/**
 * This is your application router.  From here you can controll all the incoming routes to your application.
 *
 * https://coldbox.ortusbooks.com/the-basics/routing
 */
component {

	function configure(){
		/**
		 * --------------------------------------------------------------------------
		 * App Routes
		 * --------------------------------------------------------------------------
		 * Here is where you can register the routes for your web application!
		 * Go get Funky!
		 */

		// A nice healthcheck route example
		route( "/healthcheck", function( event, rc, prc ){
			return "Ok!";
		} );

		// A nice RESTFul Route example
		route( "/api/echo", function( event, rc, prc ){
			return { "error" : false, "data" : "Welcome to my awesome API!" };
		} );

		// @app_routes@

		// Scope-contamination reproduction endpoints
		route( "/repro/alpha" ).to( "Repro.alpha" );
		route( "/repro/bravo" ).to( "Repro.bravo" );
		route( "/repro/wire" ).to( "Repro.wire" );
		route( "/repro/tempvar" ).to( "Repro.tempvar" );
		route( "/repro/status" ).to( "Repro.status" );
		route( "/repro/stress" ).to( "Repro.stress" );

		// Database-free endpoints for measuring CFC construction overhead
		route( "/benchmark/control" ).to( "Benchmark.control" );
		route( "/benchmark/construct" ).to( "Benchmark.construct" );
		route( "/benchmark/engine" ).to( "Benchmark.engine" );
		route( "/benchmark/quickconstruct" ).to( "Benchmark.quickConstruct" );

		// Adversarial construction-lock probes (plan section 2d, scripts/Invoke-LockStressTests.ps1)
		route( "/torture/p1" ).to( "Torture.p1" );
		route( "/torture/p2" ).to( "Torture.p2" );
		route( "/torture/p2both" ).to( "Torture.p2both" );
		route( "/torture/p3" ).to( "Torture.p3" );
		route( "/torture/p4" ).to( "Torture.p4" );
		route( "/torture/p5" ).to( "Torture.p5" );
		route( "/torture/p6" ).to( "Torture.p6" );
		route( "/torture/p7" ).to( "Torture.p7" );
		route( "/torture/p8" ).to( "Torture.p8" );
		route( "/torture/locks" ).to( "Torture.locks" );
		route( "/torture/reset" ).to( "Torture.reset" );

		// Conventions-Based Routing
		route( ":handler/:action?" ).end();
	}

}
