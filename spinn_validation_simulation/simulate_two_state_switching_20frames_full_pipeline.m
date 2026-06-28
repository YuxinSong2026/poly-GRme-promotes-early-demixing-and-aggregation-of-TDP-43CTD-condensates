function simulate_two_state_switching_20frames()
%% ============================================================
% Generate 20-frame two-state switching Brownian trajectories
%
% 功能：
% 1. 生成 1000 条 20-frame 轨迹
% 2. 每条轨迹内部可以发生 slow <-> fast 状态切换
% 3. 每一帧保存 ground-truth state 和 ground-truth D
% 4. 每一步 frame k -> frame k+1 保存 ground-truth state 和 D
% 5. 输出 Excel ground truth
% 6. 输出可以直接输入 SPINN 的 CSV 文件
%
% 物理模型：
%   dx, dy ~ N(0, 2Ddt)
%
% 单位：
%   position: um
%   D: um^2/s
%   dt: s
%% ============================================================

clear; clc;

%% =========================
% 1. 参数设置
%% =========================
rng(10);                    % 固定随机种子，保证可重复

nTracks = 1000;             % 轨迹数量
nFrames = 30;               % 每条轨迹帧数
nSteps = nFrames - 1;       % 每条轨迹 step 数

dt = 0.01;                  % 帧间隔，单位 s

D_slow = 0.01;              % slow state diffusion coefficient, um^2/s
D_fast = 0.20;              % fast state diffusion coefficient, um^2/s
D_values = [D_slow; D_fast];

% 状态编号：
% 1 = slow
% 2 = fast

% Markov 状态转移矩阵
% P(i,j) 表示当前状态 i 下一步转移到状态 j 的概率
%
% 这里设置为对称切换：
% slow 有 8% 概率切到 fast
% fast 有 8% 概率切到 slow
%
% 如果你想减少切换，把 pSwitch 改成 0.05
% 如果你想增加切换，把 pSwitch 改成 0.10 或 0.15

pSwitch = 0.08;

P = [1 - pSwitch, pSwitch;
     pSwitch,     1 - pSwitch];

% 是否强制每条轨迹至少发生一次 slow/fast 切换
% true  = 每条轨迹至少切换一次
% false = 自然 Markov 过程，有些轨迹可能 20 帧内没有切换
forceAtLeastOneSwitch = true;

% 初始位置随机范围，单位 um
startBox_um = 1.0;

% 定位误差
% 0 表示不加入定位误差
% 0.02 表示加入 20 nm 定位误差
locSigma_um = 0.0;

%% =========================
% 2. 随机设置每条轨迹的初始状态
%% =========================
% 让初始 slow / fast 数量各占一半，
% 但 TrackID 顺序随机打乱。

nInitialSlow = nTracks / 2;
nInitialFast = nTracks / 2;

initialStateList = [ones(nInitialSlow, 1); 2 * ones(nInitialFast, 1)];
initialStateList = initialStateList(randperm(nTracks));

%% =========================
% 3. 预分配存储空间
%% =========================
nFrameRows = nTracks * nFrames;
nStepRows = nTracks * nSteps;

% Frame-level data
Frame_TrackID = zeros(nFrameRows, 1);
Frame_Frame = zeros(nFrameRows, 1);
Frame_X_true = zeros(nFrameRows, 1);
Frame_Y_true = zeros(nFrameRows, 1);
Frame_X_obs = zeros(nFrameRows, 1);
Frame_Y_obs = zeros(nFrameRows, 1);
Frame_StateID = zeros(nFrameRows, 1);
Frame_StateName = strings(nFrameRows, 1);
Frame_D_true = zeros(nFrameRows, 1);
Frame_HasOutgoingStep = false(nFrameRows, 1);
Frame_IsSwitchFrame = false(nFrameRows, 1);

% Step-level data
Step_TrackID = zeros(nStepRows, 1);
Step_Step = zeros(nStepRows, 1);
Step_FrameStart = zeros(nStepRows, 1);
Step_FrameEnd = zeros(nStepRows, 1);
Step_StateID = zeros(nStepRows, 1);
Step_StateName = strings(nStepRows, 1);
Step_D_true = zeros(nStepRows, 1);
Step_IsSwitchFromPreviousStep = false(nStepRows, 1);
Step_dx_true = zeros(nStepRows, 1);
Step_dy_true = zeros(nStepRows, 1);
Step_stepLength_true = zeros(nStepRows, 1);
Step_D_singleStep_true = zeros(nStepRows, 1);
Step_dx_obs = zeros(nStepRows, 1);
Step_dy_obs = zeros(nStepRows, 1);
Step_stepLength_obs = zeros(nStepRows, 1);
Step_D_singleStep_obs = zeros(nStepRows, 1);

% Trajectory summary
Summary_TrackID = zeros(nTracks, 1);
Summary_InitialStateID = zeros(nTracks, 1);
Summary_InitialStateName = strings(nTracks, 1);
Summary_nSwitches = zeros(nTracks, 1);
Summary_nSlowSteps = zeros(nTracks, 1);
Summary_nFastSteps = zeros(nTracks, 1);
Summary_fractionSlowSteps = zeros(nTracks, 1);
Summary_fractionFastSteps = zeros(nTracks, 1);

% SPINN input
SPINN_TrackID = zeros(nFrameRows, 1);
SPINN_Frame = zeros(nFrameRows, 1);
SPINN_X_um = zeros(nFrameRows, 1);
SPINN_Y_um = zeros(nFrameRows, 1);

%% =========================
% 4. 逐条生成轨迹
%% =========================
for trackID = 1:nTracks

    initialState = initialStateList(trackID);

    %% -------------------------
    % 4.1 生成 step-level state sequence
    %
    % state_step(k) 表示 frame k -> frame k+1 这一步使用的状态
    %% -------------------------
    state_step = generate_state_sequence( ...
        initialState, P, nSteps, forceAtLeastOneSwitch);

    D_step = D_values(state_step);

    %% -------------------------
    % 4.2 根据每一步的 D 生成 Brownian displacement
    %% -------------------------
    sigma_step = sqrt(2 .* D_step .* dt);

    dx_true = sigma_step .* randn(nSteps, 1);
    dy_true = sigma_step .* randn(nSteps, 1);

    x0 = startBox_um * rand;
    y0 = startBox_um * rand;

    x_true = x0 + [0; cumsum(dx_true)];
    y_true = y0 + [0; cumsum(dy_true)];

    %% -------------------------
    % 4.3 加定位误差，得到观测轨迹
    %% -------------------------
    x_obs = x_true + locSigma_um * randn(nFrames, 1);
    y_obs = y_true + locSigma_um * randn(nFrames, 1);

    dx_obs = diff(x_obs);
    dy_obs = diff(y_obs);

    %% -------------------------
    % 4.4 生成 frame-level state
    %
    % 对于 frame 1 到 frame 19：
    %   frame state = 从该帧出发的 step state
    %
    % 对于最后一帧 frame 20：
    %   没有 outgoing step，因此沿用最后一个 step 的 state
    %% -------------------------
    state_frame = [state_step; state_step(end)];
    D_frame = D_values(state_frame);

    hasOutgoingStep = [true(nSteps, 1); false];

    % 标记状态切换发生的 frame
    % 如果 state_step(k) 与 state_step(k-1) 不同，
    % 则 frame k 是一个真实状态切换后的第一帧。
    isSwitchFrame = [false; diff(state_step) ~= 0; false];

    %% -------------------------
    % 4.5 保存 FrameData
    %% -------------------------
    frameIdx = (trackID - 1) * nFrames + (1:nFrames);

    Frame_TrackID(frameIdx) = trackID;
    Frame_Frame(frameIdx) = (1:nFrames)';
    Frame_X_true(frameIdx) = x_true;
    Frame_Y_true(frameIdx) = y_true;
    Frame_X_obs(frameIdx) = x_obs;
    Frame_Y_obs(frameIdx) = y_obs;
    Frame_StateID(frameIdx) = state_frame;
    Frame_D_true(frameIdx) = D_frame;
    Frame_HasOutgoingStep(frameIdx) = hasOutgoingStep;
    Frame_IsSwitchFrame(frameIdx) = isSwitchFrame;

    stateNameFrame = strings(nFrames, 1);
    stateNameFrame(state_frame == 1) = "slow";
    stateNameFrame(state_frame == 2) = "fast";
    Frame_StateName(frameIdx) = stateNameFrame;

    %% -------------------------
    % 4.6 保存 StepData
    %% -------------------------
    stepIdx = (trackID - 1) * nSteps + (1:nSteps);

    stepLength_true = sqrt(dx_true.^2 + dy_true.^2);
    stepLength_obs = sqrt(dx_obs.^2 + dy_obs.^2);

    % 单步反推 D，仅作为参考
    % 它会因为 Brownian 随机性强烈波动，不应逐步等于 D_true
    D_singleStep_true = (dx_true.^2 + dy_true.^2) ./ (4 * dt);
    D_singleStep_obs = (dx_obs.^2 + dy_obs.^2) ./ (4 * dt);

    isSwitchFromPreviousStep = [false; diff(state_step) ~= 0];

    Step_TrackID(stepIdx) = trackID;
    Step_Step(stepIdx) = (1:nSteps)';
    Step_FrameStart(stepIdx) = (1:nSteps)';
    Step_FrameEnd(stepIdx) = (2:nFrames)';
    Step_StateID(stepIdx) = state_step;
    Step_D_true(stepIdx) = D_step;
    Step_IsSwitchFromPreviousStep(stepIdx) = isSwitchFromPreviousStep;

    stateNameStep = strings(nSteps, 1);
    stateNameStep(state_step == 1) = "slow";
    stateNameStep(state_step == 2) = "fast";
    Step_StateName(stepIdx) = stateNameStep;

    Step_dx_true(stepIdx) = dx_true;
    Step_dy_true(stepIdx) = dy_true;
    Step_stepLength_true(stepIdx) = stepLength_true;
    Step_D_singleStep_true(stepIdx) = D_singleStep_true;

    Step_dx_obs(stepIdx) = dx_obs;
    Step_dy_obs(stepIdx) = dy_obs;
    Step_stepLength_obs(stepIdx) = stepLength_obs;
    Step_D_singleStep_obs(stepIdx) = D_singleStep_obs;

    %% -------------------------
    % 4.7 保存 SPINN 输入数据
    %
    % 默认用观测坐标 X_obs / Y_obs
    % 当 locSigma_um = 0 时，X_obs = X_true
    %% -------------------------
    SPINN_TrackID(frameIdx) = trackID;
    SPINN_Frame(frameIdx) = (1:nFrames)';
    SPINN_X_um(frameIdx) = x_obs;
    SPINN_Y_um(frameIdx) = y_obs;

    %% -------------------------
    % 4.8 保存 Trajectory summary
    %% -------------------------
    Summary_TrackID(trackID) = trackID;
    Summary_InitialStateID(trackID) = initialState;

    if initialState == 1
        Summary_InitialStateName(trackID) = "slow";
    else
        Summary_InitialStateName(trackID) = "fast";
    end

    Summary_nSwitches(trackID) = sum(diff(state_step) ~= 0);
    Summary_nSlowSteps(trackID) = sum(state_step == 1);
    Summary_nFastSteps(trackID) = sum(state_step == 2);
    Summary_fractionSlowSteps(trackID) = Summary_nSlowSteps(trackID) / nSteps;
    Summary_fractionFastSteps(trackID) = Summary_nFastSteps(trackID) / nSteps;

end

%% =========================
% 5. 组织成 table
%% =========================
FrameData = table( ...
    Frame_TrackID, Frame_Frame, ...
    Frame_X_true, Frame_Y_true, ...
    Frame_X_obs, Frame_Y_obs, ...
    Frame_StateID, Frame_StateName, Frame_D_true, ...
    Frame_HasOutgoingStep, Frame_IsSwitchFrame, ...
    'VariableNames', { ...
    'TrackID', 'Frame', ...
    'X_true_um', 'Y_true_um', ...
    'X_obs_um', 'Y_obs_um', ...
    'StateID_frame', 'StateName_frame', 'D_frame_true_um2_s', ...
    'HasOutgoingStep', 'IsSwitchFrame'} );

StepData = table( ...
    Step_TrackID, Step_Step, Step_FrameStart, Step_FrameEnd, ...
    Step_StateID, Step_StateName, Step_D_true, ...
    Step_IsSwitchFromPreviousStep, ...
    Step_dx_true, Step_dy_true, Step_stepLength_true, Step_D_singleStep_true, ...
    Step_dx_obs, Step_dy_obs, Step_stepLength_obs, Step_D_singleStep_obs, ...
    'VariableNames', { ...
    'TrackID', 'Step', 'Frame_start', 'Frame_end', ...
    'StateID_step', 'StateName_step', 'D_step_true_um2_s', ...
    'IsSwitchFromPreviousStep', ...
    'dx_true_um', 'dy_true_um', 'step_length_true_um', 'D_single_step_true_um2_s', ...
    'dx_obs_um', 'dy_obs_um', 'step_length_obs_um', 'D_single_step_obs_um2_s'} );

SummaryTable = table( ...
    Summary_TrackID, ...
    Summary_InitialStateID, Summary_InitialStateName, ...
    Summary_nSwitches, ...
    Summary_nSlowSteps, Summary_nFastSteps, ...
    Summary_fractionSlowSteps, Summary_fractionFastSteps, ...
    'VariableNames', { ...
    'TrackID', ...
    'InitialStateID', 'InitialStateName', ...
    'nSwitches', ...
    'nSlowSteps', 'nFastSteps', ...
    'FractionSlowSteps', 'FractionFastSteps'} );

SPINNInput = table( ...
    SPINN_TrackID, SPINN_Frame, SPINN_X_um, SPINN_Y_um, ...
    'VariableNames', {'TrackID', 'Frame', 'X_um', 'Y_um'} );

ParamNames = { ...
    'nTracks';
    'nFrames';
    'nSteps';
    'dt_s';
    'D_slow_um2_s';
    'D_fast_um2_s';
    'pSwitch';
    'P_slow_to_slow';
    'P_slow_to_fast';
    'P_fast_to_slow';
    'P_fast_to_fast';
    'forceAtLeastOneSwitch';
    'locSigma_um';
    'startBox_um';
    'random_seed'};

ParamValues = { ...
    nTracks;
    nFrames;
    nSteps;
    dt;
    D_slow;
    D_fast;
    pSwitch;
    P(1,1);
    P(1,2);
    P(2,1);
    P(2,2);
    forceAtLeastOneSwitch;
    locSigma_um;
    startBox_um;
    10};

ParamTable = table(ParamNames, ParamValues);

%% =========================
% 6. 输出文件
%% =========================
excelFile = 'two_state_switching_20frames_ground_truth.xlsx';
csvFile = 'two_state_switching_20frames_for_SPINN.csv';

if exist(excelFile, 'file')
    delete(excelFile);
end

if exist(csvFile, 'file')
    delete(csvFile);
end

writetable(FrameData, excelFile, 'Sheet', 'FrameData');
writetable(StepData, excelFile, 'Sheet', 'StepData');
writetable(SummaryTable, excelFile, 'Sheet', 'TrajectorySummary');
writetable(ParamTable, excelFile, 'Sheet', 'Parameters');

writetable(SPINNInput, csvFile);

fprintf('\nDone.\n');
fprintf('Ground-truth Excel saved to: %s\n', excelFile);
fprintf('SPINN input CSV saved to: %s\n', csvFile);

%% =========================
% 7. 输出简单检查结果
%% =========================
fprintf('\nSimulation summary:\n');
fprintf('Total tracks: %d\n', nTracks);
fprintf('Frames per track: %d\n', nFrames);
fprintf('D_slow = %.4f um^2/s\n', D_slow);
fprintf('D_fast = %.4f um^2/s\n', D_fast);
fprintf('pSwitch = %.4f\n', pSwitch);
fprintf('Tracks with at least one switch: %d / %d\n', ...
    sum(SummaryTable.nSwitches > 0), nTracks);
fprintf('Mean number of switches per track: %.3f\n', ...
    mean(SummaryTable.nSwitches));
fprintf('Total slow steps: %d\n', sum(SummaryTable.nSlowSteps));
fprintf('Total fast steps: %d\n', sum(SummaryTable.nFastSteps));

disp('First 30 trajectory summaries:');
nShowCheck = min(30, height(SummaryTable));
disp(SummaryTable(1:nShowCheck, :));

%% =========================
% 8. 画示例轨迹
%% =========================
figure;
hold on;

nShow = 20;

for i = 1:nShow
    idx = FrameData.TrackID == i;

    x = FrameData.X_obs_um(idx);
    y = FrameData.Y_obs_um(idx);
    state = FrameData.StateID_frame(idx);

    for k = 1:nFrames-1
        if state(k) == 1
            plot(x(k:k+1), y(k:k+1), '-o', 'LineWidth', 1.0);
        else
            plot(x(k:k+1), y(k:k+1), '-s', 'LineWidth', 1.0);
        end
    end
end

axis equal;
xlabel('X (\mum)');
ylabel('Y (\mum)');
title('Example 20-frame two-state switching trajectories');
box on;

%% =========================
% 9. 画 ground-truth D 分布
%% =========================
figure;
histogram(StepData.D_step_true_um2_s, 'BinMethod', 'auto');
xlabel('Ground-truth D_{step} (\mum^2/s)');
ylabel('Counts');
title('Ground-truth step-level D distribution');
box on;

end

%% ============================================================
% Local function: generate Markov state sequence
%% ============================================================
function state_step = generate_state_sequence(initialState, P, nSteps, forceAtLeastOneSwitch)

maxAttempts = 1000;

for attempt = 1:maxAttempts

    state_step = zeros(nSteps, 1);
    state_step(1) = initialState;

    for k = 2:nSteps
        prevState = state_step(k-1);

        r = rand;
        if r <= P(prevState, 1)
            state_step(k) = 1;
        else
            state_step(k) = 2;
        end
    end

    if ~forceAtLeastOneSwitch
        return;
    end

    if any(diff(state_step) ~= 0)
        return;
    end

end

% 如果尝试 maxAttempts 次后仍然没有切换，
% 则手动强制一次切换，保证该轨迹为 two-state switching trajectory。
if forceAtLeastOneSwitch && ~any(diff(state_step) ~= 0)
    switchPoint = randi([2, nSteps]);
    state_step(switchPoint:end) = 3 - state_step(switchPoint-1);
end

end