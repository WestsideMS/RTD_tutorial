%% description
% In this script, we first create constraints on the trajectory parameters
% given a random polygonal obstacle. Then, we optimize over the trajectory
% parameters to find a feasible, safe trajectory.
%
% Author: Shreyas Kousik
% Created: 30 May 2019
% Updated: 29 Oct 2019
%
%% user parameters
% robot initial condition (note that x, y, and h are 0 for this example)
v_0 = 0.5 ; % m/s

% robot desired location
x_des = 0.75 ;
y_des = 0.5 ;

% obstacle
obstacle_location = [1 ; 0] ; % (x,y)
obstacle_scale = 1.0 ;
N_vertices = 5 ;
obstacle_buffer = 0.05 ; % m

%% automated from here
% load FRS
disp('Loading fastest feasible FRS')
if v_0 >= 1.0 && v_0 <= 1.5
    FRS = load('turtlebot_FRS_deg_10_v_0_1.0_to_1.5.mat') ;
elseif v_0 >= 0.5
    FRS = load('turtlebot_FRS_deg_10_v_0_0.5_to_1.0.mat') ;
elseif v_0 >= 0.0
    FRS = load('turtlebot_FRS_deg_10_v_0_0.0_to_0.5.mat') ;
else
    error('Please pick an initial speed between 0.0 and 1.5 m/s')
end
    
% create turtlebot
A = turtlebot_agent ;
z_initial = [0;0;0] ; % initial (x,y,h)
A.reset([0;0;0;v_0])

% create obstacle
O = make_random_polygon(N_vertices,obstacle_location,obstacle_scale) ;

%% create cost function
% create waypoint from desired location
z_goal = [x_des; y_des] ;

% transform waypoint to FRS coordinates
z_goal_local = world_to_local(A.state(:,end),z_goal) ;

% use waypoint to make cost function
cost = @(k) turtlebot_cost_for_fmincon(k,FRS,z_goal_local) ;

%% create constraint function
% discretize obstacle
point_spacing = compute_turtlebot_point_spacings(A.footprint,obstacle_buffer) ;
[O_FRS, O_buf, O_pts] = compute_turtlebot_discretized_obs(O,...
                    A.state(:,end),obstacle_buffer,point_spacing,FRS) ;

% get FRS polynomial and variables
FRS_msspoly = FRS.FRS_polynomial - 1 ; % the -1 is really important!
k = FRS.k ;
z = FRS.z ;

% decompose polynomial into simplified structure (this speeds up the
% evaluation of the polynomial on obstacle points)
FRS_poly = get_FRS_polynomial_structure(FRS_msspoly,z,k) ;

% swap the speed and steer parameters for visualization purposes
FRS_poly_viz = subs(FRS_msspoly,k,[k(2);k(1)]) ;

% evaluate the FRS polynomial structure input on the obstacle points to get
% the list of constraint polynomials
cons_poly = evaluate_FRS_polynomial_on_obstacle_points(FRS_poly,O_FRS) ;

% get the gradient of the constraint polynomials
cons_poly_grad = get_constraint_polynomial_gradient(cons_poly) ;

% create nonlinear constraint function for fmincon
nonlcon = @(k) turtlebot_nonlcon_for_fmincon(k,cons_poly,cons_poly_grad) ;

% create bounds for yaw rate
k_1_bounds = [-1,1] ;

% create bounds for speed
v_0 = v_0 ;
v_max = FRS.v_range(2) ;
v_des_lo = max(v_0 - FRS.delta_v, FRS.v_range(1)) ;
v_des_hi = min(v_0 + FRS.delta_v, FRS.v_range(2)) ;
k_2_lo = (v_des_lo - v_max/2)*(2/v_max) ;
k_2_hi = (v_des_hi - v_max/2)*(2/v_max) ;
k_2_bounds = [k_2_lo, k_2_hi] ;

% combine bounds
k_bounds = [k_1_bounds ; k_2_bounds] ;

%% run trajectory optimization
% create initial guess
initial_guess = zeros(2,1) ;

% create optimization options
options =  optimoptions('fmincon',...
                'MaxFunctionEvaluations',1e5,...
                'MaxIterations',1e5,...
                'OptimalityTolerance',1e-3',...
                'CheckGradients',false,...
                'FiniteDifferenceType','central',...
                'Diagnostics','off',...
                'SpecifyConstraintGradient',true,...
                'SpecifyObjectiveGradient',true);

% call fmincon
[k_opt,~,exitflag] = fmincon(cost,...
                            initial_guess,...
                            [],[],... % linear inequality constraints
                            [],[],... % linear equality constraints
                            k_bounds(:,1),... % lower bounds
                            k_bounds(:,2),... % upper bounds
                            nonlcon,...
                            options) ;
                        
% check the exitflag
if exitflag <= 0
    k_opt = [] ;
end

%% get contour of trajopt output
if ~isempty(k_opt)
    I_z_opt = msubs(FRS_msspoly,k,k_opt) ;
    
    x0 = FRS.initial_x ;
    y0 = FRS.initial_y ;
    D = FRS.distance_scale ;
    
    C_FRS = get_2D_contour_points(I_z_opt,z,0) ;
    C_world = FRS_to_world(C_FRS,A.state(:,end),x0,y0,D) ;
end

%% get parameter space obstacles
I_k = msubs(FRS_poly_viz,z,O_FRS) ;

%% move robot
if ~isempty(k_opt)
    w_des = full(msubs(FRS.w_des,k,k_opt)) ;
    v_des = full(msubs(FRS.v_des,k,k_opt)) ;

    % create the desired trajectory
    t_plan = FRS.t_plan ;
    t_stop = v_des / A.max_accel ;
    [T_brk,U_brk,Z_brk] = make_turtlebot_braking_trajectory(t_plan,t_stop,w_des,v_des) ;
    
    % move the robot
    A.move(T_brk(end),T_brk,U_brk,Z_brk) ;
end

%% plot actual xy space
figure(1) ; clf ;

subplot(1,3,3) ; hold on ; axis equal ; set(gca,'FontSize',15)

% plot robot
plot(A)

% plot buffered obstacle
patch(O_buf(1,:),O_buf(2,:),[1 0.5 0.6])

% plot actual obstacle
patch(O(1,:),O(2,:),[1 0.7 0.8])

% plot discretized obstacle
plot(O_pts(1,:),O_pts(2,:),'.','Color',[0.5 0.1 0.1],'MarkerSize',15)

% plot desired location
plot(x_des,y_des,'k*','LineWidth',2,'MarkerSize',15)

% plot test value of k and desired trajectory
if ~isempty(k_opt)
    plot_path(Z_brk,'b--','LineWidth',1.5)
    I_z_test = msubs(FRS_msspoly,k,k_opt) ;
    plot(C_world(1,:),C_world(2,:),'Color',[0.3 0.8 0.5],'LineWidth',1.5)
end

% set axis limits
axis([-0.5,1.5,-1,1])

% labeling
title('World Frame')
xlabel('x [m]')
ylabel('y [m]')

%% plot FRS frame
h_Z0 = FRS.h_Z0 ;

subplot(1,3,2) ; hold on ; axis equal ; grid on ; set(gca,'FontSize',15)

% plot initial condition set
plot_2D_msspoly_contour(h_Z0,z,0,'Color',[0 0 1],'LineWidth',1.5)

% plot FRS obstacles
plot(O_FRS(1,:),O_FRS(2,:),'.','Color',[0.5 0.1 0.1],'MarkerSize',15)

% plot test value of k
if ~isempty(k_opt)
    plot(C_FRS(1,:),C_FRS(2,:),'Color',[0.3 0.8 0.5],'LineWidth',1.5)
end

% labeling
title('FRS Frame')
xlabel('x (scaled)')
ylabel('y (scaled)')

%% plot traj param space
subplot(1,3,1) ; hold on ; axis equal ; set(gca,'FontSize',15)

% plot obstacle point contours
for idx = 1:length(I_k)
    I_idx = I_k(idx) ;
    plot_2D_msspoly_contour(I_idx,k,0,'FillColor',[1 0.5 0.6])
end

% plot k_opt
if ~isempty(k_opt)
    plot(k_opt(2),k_opt(1),'.','Color',[0.3 0.8 0.5],'MarkerSize',15)
    plot(k_opt(2),k_opt(1),'ko','MarkerSize',6)
end

% label
title('Traj Params')
xlabel('speed param')
ylabel('yaw rate param')