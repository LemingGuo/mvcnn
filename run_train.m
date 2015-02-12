function net = run_train(imdbName, varargin)
%RUN_TRAIN Train a CNN model on a provided dataset 
%
%   imdbName:: 
%       must be name of a folder under data/
%   `seed`:: 1
%       random seed
%   `batchSize`: 128
%       set to a smaller number on limited memory
%   `gpuMode`:: false
%       set to true to compute on GPU
%   `modelName`:: 'imagenet-vgg-m'
%       set to empty to train from scratch
%   `prefix`:: 'v1'
%       additional experiment identifier
%   `numFetchThreads`::
%       #threads for vl_imreadjpeg
%   `augmentation`:: 'f2'
%       specifies the operations (fliping, perturbation, etc.) used 
%       to get sub-regions
% 
opts.seed = 1 ;
opts.batchSize = 128 ;
opts.gpuMode = false;
opts.modelName = 'imagenet-vgg-m';
opts.prefix = 'v1' ;
opts.numFetchThreads = 0 ;
opts.augmentation = 'f2';
opts = vl_argparse(opts, varargin) ;

if ~isempty(opts.modelName), 
    opts.expDir = sprintf('%s-finetuned-%s', opts.modelName, imdbName); 
else
    opts.expDir = imdbName; 
end
opts.expDir = fullfile('data', opts.prefix, ...
    sprintf('%s-seed-%02d', opts.expDir, opts.seed));
opts = vl_argparse(opts,varargin) ;

if ~exist(opts.expDir, 'dir'), vl_xmkdir(opts.expDir) ; end

% Setup GPU if needed
if opts.gpuMode
  gpuDevice(1) ;
end

% -------------------------------------------------------------------------
%                                                                 Get imdb
% -------------------------------------------------------------------------
imdb = get_imdb(imdbName);
if isfield(imdb.meta,'invert'), 
    opts.invert = imdb.meta.invert;
else
    opts.invert = false;
end

% -------------------------------------------------------------------------
%                                                    Network initialization
% -------------------------------------------------------------------------

net = initializeNetwork(opts.modelName, imdb.meta.classes) ;

% Initialize average image
if isempty(net.normalization.averageImage), 
    % compute the average image
    averageImagePath = fullfile(opts.expDir, 'average.mat') ;
    if exist(averageImagePath, 'file')
      load(averageImagePath, 'averageImage') ;
    else
      train = find(imdb.images.set == 1) ;
      bs = 256 ;
      fn = getBatchWrapper(net.normalization, 'numThreads',...
          opts.numFetchThreads,'augmentation', opts.augmentation);
      for t=1:bs:numel(train)
        batch_time = tic ;
        batch = train(t:min(t+bs-1, numel(train))) ;
        fprintf('Computing average image: processing batch starting with image %d ...', batch(1)) ;
        temp = fn(imdb, batch) ;
        im{t} = mean(temp, 4) ;
        batch_time = toc(batch_time) ;
        fprintf(' %.2f s (%.1f images/s)\n', batch_time, numel(batch)/ batch_time) ;
      end
      averageImage = mean(cat(4, im{:}),4) ;
      save(averageImagePath, 'averageImage') ;
    end

    net.normalization.averageImage = averageImage ;
    clear averageImage im temp ;
end

% -------------------------------------------------------------------------
%                                               Stochastic gradient descent
% -------------------------------------------------------------------------
trainOpts.batchSize = opts.batchSize ;
trainOpts.useGpu = opts.gpuMode ;
trainOpts.expDir = opts.expDir ;
trainOpts.numEpochs = 30 ;
trainOpts.continue = true ;
trainOpts.prefetch = false ;
trainOpts.learningRate = [0.001*ones(1, 10) 0.0001*ones(1, 10) 0.00001*ones(1,10)] ;
trainOpts.conserveMemory = true;

fn = getBatchWrapper(net.normalization,'numThreads',opts.numFetchThreads, ...
    'augmentation', opts.augmentation, 'invert', opts.invert);

[net,info] = cnn_train(net, imdb, fn, trainOpts) ;

% Save model
net = vl_simplenn_move(net, 'cpu');
net = saveNetwork(fullfile(opts.expDir, 'final-model.mat'), net);

% -------------------------------------------------------------------------
function net = saveNetwork(fileName, net)
% -------------------------------------------------------------------------
layers = net.layers;

% Replace the last layer with softmax
layers{end}.type = 'softmax';
layers{end}.name = 'prob';

% Remove fields corresponding to training parameters
ignoreFields = {'filtersMomentum', ...
                'biasesMomentum',...
                'filtersLearningRate',...
                'biasesLearningRate',...
                'filtersWeightDecay',...
                'biasesWeightDecay',...
                'class'};
for i = 1:length(layers),
    layers{i} = rmfield(layers{i}, ignoreFields(isfield(layers{i}, ignoreFields)));
end
net.layers = layers;
save(fileName, '-struct', 'net');


% -------------------------------------------------------------------------
function fn = getBatchWrapper(opts, varargin)
% -------------------------------------------------------------------------
fn = @(imdb,batch) getBatch(imdb,batch,opts,varargin{:}) ;

% -------------------------------------------------------------------------
function [im,labels] = getBatch(imdb, batch, opts, varargin)
% -------------------------------------------------------------------------
images = strcat([imdb.imageDir '/'], imdb.images.name(batch)) ;
[im, idxs] = get_image_batch(images, opts, ...
    'prefetch', nargout == 0, ...
    varargin{:}); 
labels = imdb.images.class(batch(idxs)) ;

% -------------------------------------------------------------------------
function net = initializeNetwork(modelName, classNames)
% -------------------------------------------------------------------------
scal = 1 ;
init_bias = 0.1;
numClass = length(classNames);

if ~isempty(modelName), 
    netFilePath = fullfile('data','models', [modelName '.mat']);
    % download model if not found
    if ~exist(netFilePath,'file'),
        fprintf('Downloading model (%s) ...', modelName) ;
        vl_xmkdir(fullfile('data','models')) ;
        urlwrite(fullfile('http://www.vlfeat.org/matconvnet/models', ...
            [modelName '.mat']), netFilePath) ;
        fprintf(' done!\n');
    end
    net = load(netFilePath); % Load model if specified
    
    fprintf('Initializing from model: %s\n', modelName);
    % Replace the last but one layer with random weights
    widthPenultimate = size(net.layers{end-1}.filters,3); 
    net.layers{end-1} = struct('name','fc8', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(1,1,widthPenultimate,numClass,'single'), ...
                           'biases', zeros(1, numClass, 'single'), ...
                           'stride', 1, ...
                           'pad', 0, ...
                           'filtersLearningRate', 10, ...
                           'biasesLearningRate', 20, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0);
                       
    % Last layer is softmaxloss (switch to softmax for prediction)
    net.layers{end} = struct('type', 'softmaxloss') ;

    % Rename classes
    net.classes.name = classNames;
    net.classes.description = classNames;
    return;
end

% Else initial model randomly
net.layers = {} ;

% Block 1
net.layers{end+1} = struct('name', 'conv1', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(11, 11, 3, 96, 'single'), ...
                           'biases', zeros(1, 96, 'single'), ...
                           'stride', 4, ...
                           'pad', 0, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;
net.layers{end+1} = struct('type', 'pool', ...
                           'method', 'max', ...
                           'pool', [3 3], ...
                           'stride', 2, ...
                           'pad', 0) ;
net.layers{end+1} = struct('type', 'normalize', ...
                           'param', [5 1 0.0001/5 0.75]) ;

% Block 2
net.layers{end+1} = struct('name', 'conv2', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(5, 5, 48, 256, 'single'), ...
                           'biases', init_bias*ones(1, 256, 'single'), ...
                           'stride', 1, ...
                           'pad', 2, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;
net.layers{end+1} = struct('type', 'pool', ...
                           'method', 'max', ...
                           'pool', [3 3], ...
                           'stride', 2, ...
                           'pad', 0) ;
net.layers{end+1} = struct('type', 'normalize', ...
                           'param', [5 1 0.0001/5 0.75]) ;

% Block 3
net.layers{end+1} = struct('name', 'conv3', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(3,3,256,384,'single'), ...
                           'biases', init_bias*ones(1,384,'single'), ...
                           'stride', 1, ...
                           'pad', 1, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;

% Block 4
net.layers{end+1} = struct('name', 'conv4', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(3,3,192,384,'single'), ...
                           'biases', init_bias*ones(1,384,'single'), ...
                           'stride', 1, ...
                           'pad', 1, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;

% Block 5
net.layers{end+1} = struct('name', 'conv5', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(3,3,192,256,'single'), ...
                           'biases', init_bias*ones(1,256,'single'), ...
                           'stride', 1, ...
                           'pad', 1, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;
net.layers{end+1} = struct('type', 'pool', ...
                           'method', 'max', ...
                           'pool', [3 3], ...
                           'stride', 2, ...
                           'pad', 0) ;

% Block 6
net.layers{end+1} = struct('name', 'fc6', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(6,6,256,4096,'single'),...
                           'biases', init_bias*ones(1,4096,'single'), ...
                           'stride', 1, ...
                           'pad', 0, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;
net.layers{end+1} = struct('type', 'dropout', ...
                           'rate', 0.5) ;

% Block 7
net.layers{end+1} = struct('name', 'fc7', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(1,1,4096,4096,'single'),...
                           'biases', init_bias*ones(1,4096,'single'), ...
                           'stride', 1, ...
                           'pad', 0, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;
net.layers{end+1} = struct('type', 'relu') ;
net.layers{end+1} = struct('type', 'dropout', ...
                           'rate', 0.5) ;

% Block 8
net.layers{end+1} = struct('name', 'fc8', ...
                           'type', 'conv', ...
                           'filters', 0.01/scal * randn(1,1,4096,numClass,'single'), ...
                           'biases', zeros(1, numClass, 'single'), ...
                           'stride', 1, ...
                           'pad', 0, ...
                           'filtersLearningRate', 1, ...
                           'biasesLearningRate', 2, ...
                           'filtersWeightDecay', 1, ...
                           'biasesWeightDecay', 0) ;

% Block 9
net.layers{end+1} = struct('type', 'softmaxloss') ;

% Other details
net.normalization.imageSize = [227, 227, 3] ;
net.normalization.interpolation = 'bicubic' ;
net.normalization.border = 256 - net.normalization.imageSize(1:2) ;
net.normalization.averageImage = [] ;
net.normalization.keepAspect = true ;

