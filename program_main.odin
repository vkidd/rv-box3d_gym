
package main

import "core:math"
import "core:math/rand"
import b3d    "vendor:box3d"
import gl     "vendor:OpenGL"
import rmods  "vendor/rapidv/modules"
import rshade "vendor/rapidv/shaders"
import rsys   "vendor/rapidv/system"
import rv     "vendor/rapidv/engine"

Box3dGym :: struct
{
	// Subtype rapidv App
	using _app:       rv.App,

	commandPalette:   rmods.CommandPalette,
	inputs:           rmods.InputSystem,
	worldKit:         rmods.WorldKit,

	camera:           rv.Camera,
	entities:         rv.HandleMap(Entity, EntityHandle),
	lines:            rv.GpuLines,
	physStep:         rv.FixedTimestep,
	physWorldId:      b3d.WorldId,
	spawnTimestep:    rv.Timestep,
}

Entity :: struct
{
	using transform:  rv.Transform,
	type:             EntityType,
	handle:           EntityHandle,
	physBodyId:       b3d.BodyId,
	physTR:           rv.Transform,
	prevPhysTR:       rv.Transform,
	mesh:             rv.GpuMesh,
	lifetime:         Maybe(f32),
}

EntityHandle :: rv.Handle16

make_entity :: proc( app: ^Box3dGym, type: EntityType, tr: rv.Transform, lifetime: Maybe(f32) = nil ) -> ^Entity
{
	entity := rv.hmap_add_get( &app.entities,
		Entity{ type       = type,
				  transform  = tr,
				  physTR     = tr,
				  prevPhysTR = tr,
				  lifetime   = lifetime
		} )
	switch type
	{
		case .Box:     entity.mesh = app.worldKit.meshes.cube
		case .Capsule: entity.mesh = app.worldKit.meshes.capsule
		case .Floor:   entity.mesh = app.worldKit.meshes.cube
		case .Sphere:  entity.mesh = app.worldKit.meshes.sphere
	}
	return entity
}

delete_entity :: proc( app: ^Box3dGym, handle: EntityHandle ) -> bool
{
	if entity, ok := rv.hmap_get( app.entities, handle ); ok
	{
		if entity.physBodyId != {} do b3d.DestroyBody( entity.physBodyId )

		return rv.hmap_remove( &app.entities, handle )
	}
	return false
}

EntityType :: enum
{
	Box = 0,
	Capsule,
	Floor,
	Sphere,
}

main :: proc()
{
	loggerData: rsys.LoggerData
	context.logger = rsys.logger_make_std( &loggerData )

	backend: rsys.AppBackend
	backend, context.allocator = rsys.app_backend_make_std( "Box3d Gym" )
	defer rsys.app_backend_delete( &backend )

	app := rv.app_make( Box3dGym, "Box3d Gym", &backend )
	defer rv.app_delete( &app )
	defer rv.hmap_delete( &app.entities )

	app.worldKit = rmods.world_kit_make()
	app.commandPalette = rmods.command_palette_make()
	app.inputs = rmods.input_system_make()
	defer rmods.world_kit_delete( &app.worldKit )
	defer rmods.command_palette_delete( &app.commandPalette )
	defer rmods.input_system_delete( &app.inputs )

	rv.app_set_impl( &app, proc( app: ^Box3dGym )
	{
		rv.app_add_module( app, &app.worldKit, rmods.world_kit_get_impl() )
		rv.app_add_module( app, &app.inputs, rmods.input_system_get_impl() )
		rv.app_add_module( app, &app.commandPalette, rmods.command_palette_get_impl() )

		// Add procedures that run the app.
		rv.app_add_procedures(
			app,
			appStart    = app_start,
			frameUpdate = frame_update,
			gameUpdate  = game_update, )

		// Add rendering passes that execute in-order
		rv.app_add_render_pass( app, "main",  render_pass_main )
		rv.app_add_render_pass( app, "debug",  rv.render_pass_debug_info )
	} )
	rv.app_run( &app )   // blocks until session end
}

app_start :: proc( app: ^Box3dGym )
{
	app.builtin.showFPS = true
	app.lines = rv.gpu_lines_make( app, "debug", 128 )
	app.physStep = { interval = 1/50.0 }

	rv.imgui_apply_builtin_style( app, .XcodeDark )

	// Setup camera
	app.camera = rv.camera_make( false )
	app.camera.position = rv.relative_pos( front=30 )

	// Setup shadows
	app.worldKit.shadowBias = 0.00002
	app.worldKit.shadowDistance = 300
	app.worldKit.shadowOrthoSize = 80

	// Setup Physics
	worldDef := b3d.DefaultWorldDef()
	worldDef.gravity = rv.DIR_UP * -9.8
	app.physWorldId = b3d.CreateWorld( worldDef )

	// Dynamic body
	shapeDef := b3d.DefaultShapeDef()
	shapeDef.density = 2
	shapeDef.baseMaterial.friction = 0.5
	shapeDef.baseMaterial.restitution = 0.5

	make_floor( app, rv.transform_make( pos = rv.relative_pos( up=-8 ), scale = {60, 60, 4} ) )

	for i in 0..< 32
	{
		make_box( app, rand_transform(), shapeDef, rand.float32_range(10,20) )
	}
	for i in 0..< 32
	{
		make_capsule( app, rand_transform(), shapeDef, rand.float32_range(10,20) )
	}
	for i in 0..< 32
	{
		make_sphere( app, rand_transform(), shapeDef, rand.float32_range(10,20) )
	}
}

frame_update :: proc( app: ^Box3dGym, frameDt: rv.Seconds )
{
	radialInOut := math.sin( rv.app_get_time( app ) * 0.5 ) * 3
	rv.camera_move_within_orbit(
		&app.camera,
		rv.relative_pos( up=-3 ),
		frameDt,
		orbitSpeed  = 3,
		radialSpeed = radialInOut,
		pitch       = 24*math.RAD_PER_DEG
	 )

	rmods.world_kit_submit_uniform_blocks( &app.worldKit, app.camera )
}

game_update :: proc( app: ^Box3dGym, gameDt: rv.Seconds )
{
	// Tick Physics
	steps, _ := rv.fixed_timestep_tick( &app.physStep, gameDt )
	for i in 0..< steps
	{
		b3d.World_Step( app.physWorldId, app.physStep.interval, 4 )

		for &entity in app.entities.values
		{
			if entity.physBodyId != {}
			{
				stepTR := b3d.Body_GetTransform( entity.physBodyId )
				entity.prevPhysTR = entity.physTR
				entity.physTR     = rv.transform_make( stepTR.p, stepTR.q, entity.scale )
			}
		}
	}

	// Update entity positions
	for &entity in app.entities.values
	{
		if val, ok := entity.lifetime.?; ok
		{
			newLifetime := max( 0, val - gameDt )

			entity.lifetime = newLifetime

			if newLifetime <= 0 do delete_entity( app, entity.handle )
		}

		// Frame interpolated physics TR
		if entity.physBodyId != {}
		{
			entity.transform = rv.transform_lerp( entity.prevPhysTR, entity.physTR, app.physStep.smoothInterp01 )
		}
	}

	// Spawn stuff
	if rv.timestep_tick( &app.spawnTimestep, gameDt, 6 )
	{
		shapeDef := b3d.DefaultShapeDef()
		shapeDef.density = 2
		shapeDef.baseMaterial.friction = 0.5
		shapeDef.baseMaterial.restitution = 0.5

		for i in 0..<12
		{
			make_box( app, rand_transform(), shapeDef, rand.float32_range(10,20) )
			make_capsule( app, rand_transform(), shapeDef, rand.float32_range(10,20) )
			make_sphere( app, rand_transform(), shapeDef, rand.float32_range(10,20) )
		}
	}
}

render_pass_main :: proc( app: ^Box3dGym, screenSize: rv.Pixels2 )
{
	builtin  := &app.builtin
	kit      := &app.worldKit

	// Shadow map pass (casters only)
	{
		shadow := &kit.shaders.shadowDepth
		uni: rshade.ShadowDepthUNI
		rv.gpu_shadow_map_begin( app, &kit.shadowMap, &kit.shaders.shadowDepth )
		for entity in app.entities.values
		{
			#partial switch entity.type
			{
				case .Box, .Capsule, .Sphere:
				{
					uni.model = rv.gpu_model_mat( entity ) 
					rv.gpu_shader_set( app, shadow, uni )
					rv.gpu_mesh_draw( app, entity.mesh, shadow )
				}
			}
		}
		rv.gpu_shadow_map_end( &kit.shadowMap )
	}
	
	// Draw background clear
	gl.PolygonMode( gl.FRONT_AND_BACK, gl.FILL ) // or gl.LINE ) for wireframe
	gl.ClearColor( 0.1, 0.1, 0.09, 1 )
	gl.Clear( gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT )
	gl.Enable( gl.CULL_FACE )

	// Draw skybox
	rmods.world_kit_draw_skybox( kit )

	// Draw lines
	rv.gpu_lines_add_grid( &app.lines, center = rv.relative_pos( up=-5.99 ), halfExtent = 27, spacing = 3, thickness = 0.05 )
	rv.gpu_lines_draw( app, &app.lines, &app.worldKit.shaders.solidLine, depthTest = true )

	// Draw Entities
	{
		shader := &kit.shaders.solidColorLit
		uni: rshade.SolidColorLitUNI
		for entity in app.entities.values
		{
			uni.diffuseTex = rv.gpu_sampler( entity.type == .Floor ? builtin.defaultTex : kit.textures.uvChecker )
			uni.shadowMapTex = rv.gpu_sampler( kit.shadowMap.texture )
			uni.model = rv.gpu_model_mat( entity )
			#partial switch entity.type
			{
				case .Capsule: uni.color = rv.gpu_color( rv.COLOR_AzureBlue )
				case .Box:     uni.color = rv.gpu_color( rv.COLOR_Orange )
				case .Sphere:  uni.color = rv.gpu_color( rv.COLOR_Green )
				case .Floor:   uni.color = rv.gpu_color( rv.COLOR_Grey )
			}

			rv.gpu_shader_set( app, shader, uni )
			rv.gpu_mesh_draw( app, entity.mesh, shader )

			// Draw 2D overlay
			if screenPos, ok := rv.camera_screen_from_world( app.camera, entity.position, screenSize ); ok
			{
				rectSize := rv.Vec2{ 8, 8 }
				rect := rv.rect2d_make( screenPos.xy - rectSize*0.5, rectSize )
				rv.gpu_texture_draw_to_ui( app, app.worldKit.textures.circle, rect )
			}
		}
	}
}

//------------------------------------------------------------------------------
// Helpers
//------------------------------------------------------------------------------

rand_transform :: proc() -> rv.Transform
{
	return rv.transform_make(
		pos   = {rand.float32_range(-8,8),rand.float32_range(-8,8),rand.float32_range(-2,8)},
		rot   = rv.quat_rand(),
		scale = rand.float32_range(0.7,1.3) )
}

make_floor :: proc( app: ^Box3dGym, tr: rv.Transform )
{
	entity := make_entity( app, .Floor, tr )
	bodyDef := b3d.DefaultBodyDef()
	bodyDef.position = tr.position
	bodyDef.rotation = tr.rotation
	entity.physBodyId = b3d.CreateBody( app.physWorldId, bodyDef )

	boxHull := b3d.MakeBoxHull( tr.scale.x*0.5, tr.scale.y*0.5, tr.scale.z*0.5 )
	shapeDef := b3d.DefaultShapeDef()
	_ = b3d.CreateHullShape( entity.physBodyId, shapeDef, &boxHull.base )
}

make_box :: proc( app: ^Box3dGym, tr: rv.Transform, shape: b3d.ShapeDef, lifetime: Maybe(f32) = nil )
{
	entity := make_entity( app, .Box, tr, lifetime )
	bodyDef := b3d.DefaultBodyDef()
	bodyDef.type = .dynamicBody
	bodyDef.position = tr.position
	bodyDef.rotation = tr.rotation
	entity.physBodyId = b3d.CreateBody( app.physWorldId, bodyDef )

	boxHull := b3d.MakeCubeHull( 0.5 * tr.scale.x )
	_ = b3d.CreateHullShape( entity.physBodyId, shape, &boxHull.base )
}

make_capsule :: proc( app: ^Box3dGym, tr: rv.Transform, shape: b3d.ShapeDef, lifetime: Maybe(f32) = nil )
{
	entity := make_entity( app, .Capsule, tr, lifetime )
	bodyDef := b3d.DefaultBodyDef()
	bodyDef.type = .dynamicBody
	bodyDef.position = tr.position
	bodyDef.rotation = tr.rotation
	entity.physBodyId = b3d.CreateBody( app.physWorldId, bodyDef )

	capsule := b3d.Capsule{ rv.DIR_UP*0.3*tr.scale.x, -rv.DIR_UP*0.3*tr.scale.x, 0.2*tr.scale.x }
	_ = b3d.CreateCapsuleShape( entity.physBodyId, shape, &capsule )
}

make_sphere :: proc( app: ^Box3dGym, tr: rv.Transform, shape: b3d.ShapeDef, lifetime: Maybe(f32) = nil )
{
	entity := make_entity( app, .Sphere, tr, lifetime )
	bodyDef := b3d.DefaultBodyDef()
	bodyDef.type = .dynamicBody
	bodyDef.position = tr.position
	bodyDef.rotation = tr.rotation
	entity.physBodyId = b3d.CreateBody( app.physWorldId, bodyDef )

	sphere := b3d.Sphere{ {}, 0.5*tr.scale.x }
	_ = b3d.CreateSphereShape( entity.physBodyId, shape, &sphere )
}