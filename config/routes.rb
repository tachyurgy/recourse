Rails.application.routes.draw do
  root "queue#index"
  get  "up" => "rails/health#show", as: :rails_health_check

  resources :lenders, only: [] do
    resources :cases, only: [:index, :show], controller: "queue" do
      member { post :promote_reply }
    end
  end

  get  "cases/:id",  to: "queue#show",  as: :servicing_case
  post "cases/:id/promote", to: "queue#promote", as: :promote_case
  post "cases/:id/classify", to: "queue#classify", as: :classify_case

  get  "imports",    to: "imports#index"
  post "imports",    to: "imports#create", as: :create_import

  get  "evaluation", to: "evaluation#show", as: :evaluation
  post "evaluation/try", to: "evaluation#try", as: :try_evaluation

  get  "notes",      to: "pages#notes", as: :notes
end
